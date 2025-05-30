import CICFileManager
import CoreML
import CreateML
import Foundation
@testable import OvOClassification
import Vision
import XCTest

final class OvOClassifierTests: XCTestCase {
    var classifier: OvOClassifier!
    let fileManager = FileManager.default
    let authorName: String = "Test Author"
    let testModelName: String = "TestModel"
    let testModelVersion: String = "v1"

    let algorithm = MLImageClassifier.ModelParameters.ModelAlgorithmType.transferLearning(
        featureExtractor: .scenePrint(revision: 1),
        classifier: .logisticRegressor
    )

    var modelParameters: MLImageClassifier.ModelParameters {
        MLImageClassifier.ModelParameters(
            validation: .split(strategy: .automatic),
            maxIterations: 1,
            augmentation: [],
            algorithm: algorithm
        )
    }

    var temporaryOutputDirectoryURL: URL!
    var compiledModelURL: URL?
    var trainingResult: OvOClassification.OvOTrainingResult?

    enum TestError: Error {
        case trainingFailed
        case modelFileMissing
        case predictionFailed
        case setupFailed
        case resourcePathError
        case testResourceMissing
    }

    override func setUp() async throws {
        try await super.setUp()

        temporaryOutputDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("TestOutput_OvO")
        try fileManager.createDirectory(
            at: temporaryOutputDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let resourceDirectoryPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OvOClassifierTests
            .appendingPathComponent("TestResources")
            .appendingPathComponent("OvO")
            .path

        classifier = OvOClassifier(
            outputDirectoryPathOverride: temporaryOutputDirectoryURL.path,
            resourceDirPathOverride: resourceDirectoryPath
        )

        // モデルの作成
        trainingResult = await classifier.create(
            author: authorName,
            modelName: testModelName,
            version: testModelVersion,
            modelParameters: modelParameters
        )

        guard trainingResult != nil else {
            throw TestError.trainingFailed
        }
    }

    override func tearDownWithError() throws {
        if let tempDir = temporaryOutputDirectoryURL, fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        temporaryOutputDirectoryURL = nil

        if let compiledUrl = compiledModelURL, fileManager.fileExists(atPath: compiledUrl.path) {
            try? fileManager.removeItem(at: compiledUrl)
        }
        compiledModelURL = nil
        trainingResult = nil
        classifier.resourceDirPathOverride = nil
        classifier = nil
        try super.tearDownWithError()
    }

    func testClassifierDIConfiguration() throws {
        XCTAssertNotNil(classifier, "OvOClassifierの初期化失敗")
        XCTAssertEqual(classifier.outputParentDirPath, temporaryOutputDirectoryURL.path, "分類器の出力パスが期待値と不一致")
    }

    func testModelTrainingAndArtifactGeneration() throws {
        guard let result = trainingResult else {
            XCTFail("訓練結果がnilです (testModelTrainingAndArtifactGeneration)")
            throw TestError.trainingFailed
        }

        XCTAssertTrue(
            fileManager.fileExists(atPath: result.modelOutputPath),
            "訓練モデルファイルが期待されるパス「\(result.modelOutputPath)」に見つかりません"
        )

        let resourceURL = URL(fileURLWithPath: classifier.resourcesDirectoryPath)

        var expectedClassLabels: [String] = []
        do {
            let subdirectories = try fileManager.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            expectedClassLabels = subdirectories.filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }.map(\.lastPathComponent).sorted()
        } catch {
            XCTFail("テストリソースのサブディレクトリからのクラスラベルの取得に失敗しました: \(error.localizedDescription)")
            throw TestError.setupFailed
        }

        // モデルファイル名の検証
        let modelFilePath = result.metadata.trainedModelFilePath
        let modelFileName = URL(fileURLWithPath: modelFilePath).lastPathComponent

        // OvO分類器では各クラスの組み合わせに対して1つの分類器を作成するため、各クラス名を含むパターンを期待
        let regex = #"^TestModel_OvO_[a-z_]+_vs_[a-z_]+_v\d+\.mlmodel$"#
        XCTAssertTrue(
            modelFileName.range(of: regex, options: .regularExpression) != nil,
            """
            モデルファイル名が期待パターンに一致しません。
            期待パターン: \(regex)
            実際: \(modelFileName)
            """
        )

        result.saveLog(modelAuthor: authorName, modelName: testModelName, modelVersion: testModelVersion)
        let modelFileDir = URL(fileURLWithPath: result.metadata.trainedModelFilePath).deletingLastPathComponent()
        let expectedLogFileName = "OvO_Run_Report_\(testModelVersion).md"
        let expectedLogFilePath = modelFileDir.appendingPathComponent(expectedLogFileName).path
        XCTAssertTrue(fileManager.fileExists(atPath: expectedLogFilePath), "ログファイル「\(expectedLogFilePath)」が生成されていません")

        XCTAssertEqual(result.metadata.modelName, testModelName)
    }

    func testModelCanPerformPrediction() async throws {
        guard let result = trainingResult else {
            XCTFail("訓練結果がnil (OvO testModelCanPerformPrediction)")
            throw TestError.trainingFailed
        }

        let modelFilePath = result.metadata.trainedModelFilePath
        guard fileManager.fileExists(atPath: modelFilePath) else {
            XCTFail("モデルファイルが見つかりません: \(modelFilePath)")
            throw TestError.modelFileMissing
        }

        print("Attempting to compile model: \(modelFilePath)")
        let specificCompiledModelURL: URL
        do {
            specificCompiledModelURL = try await MLModel.compileModel(at: URL(fileURLWithPath: modelFilePath))
            compiledModelURL = specificCompiledModelURL
        } catch {
            XCTFail("モデルのコンパイル失敗 (\(modelFilePath)): \(error.localizedDescription)")
            throw TestError.modelFileMissing
        }

        let imageURL: URL
        do {
            // 存在するディレクトリからランダムに選択
            let availableClassLabels = ["sphynx", "mouth_open"]
            let randomClassLabel = availableClassLabels.randomElement()!
            imageURL = try getRandomImageURL(forClassLabel: randomClassLabel)
        } catch {
            XCTFail("テストリソースからのランダム画像取得失敗。エラー: \(error.localizedDescription)")
            throw error
        }

        print("Test image for prediction: \(imageURL.path)")

        guard fileManager.fileExists(atPath: imageURL.path) else {
            XCTFail("OvOテスト用画像ファイルが見つかりません: \(imageURL.path)")
            throw TestError.resourcePathError
        }

        let mlModel = try MLModel(contentsOf: specificCompiledModelURL)
        let visionModel = try VNCoreMLModel(for: mlModel)
        let request = VNCoreMLRequest(model: visionModel) { request, error in
            if let error {
                XCTFail("VNCoreMLRequest failed: \(error.localizedDescription)")
                return
            }
            guard let observations = request.results as? [VNClassificationObservation] else {
                XCTFail("予測結果をVNClassificationObservationにキャストできませんでした。")
                return
            }

            XCTAssertFalse(observations.isEmpty, "予測結果(observations)が空でした。モデルは予測を行いませんでした。")

            if let topResult = observations.first {
                print(
                    "OvO Top prediction for \(imageURL.lastPathComponent) using \(URL(fileURLWithPath: modelFilePath).lastPathComponent): \(topResult.identifier) with confidence \(topResult.confidence)"
                )
            } else {
                print(
                    "OvO prediction for \(imageURL.lastPathComponent) using \(URL(fileURLWithPath: modelFilePath).lastPathComponent): No observations found, though this should have been caught by XCTAssertFalse."
                )
            }
        }

        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        try handler.perform([request])
    }

    /// 各クラス組み合わせにおいて、一時ディレクトリ内の画像枚数が最小枚数に統一されていることを検証する
    func testClassImageBalance() throws {
        let resourceURL = URL(fileURLWithPath: classifier.resourcesDirectoryPath)
        let classLabels = try FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter(\.hasDirectoryPath)
        .map(\.lastPathComponent)

        // 各クラスの組み合わせで画像枚数のバランスを確認
        for i in 0 ..< classLabels.count {
            for j in (i + 1) ..< classLabels.count {
                let class1 = classLabels[i]
                let class2 = classLabels[j]

                // トレーニングデータを準備
                _ = try classifier.prepareTwoClassTrainingData(
                    class1: class1,
                    class2: class2,
                    basePath: resourceURL.path
                )

                // クラス間の画像枚数を取得
                let (class1Count, class2Count) = try classifier.balanceClassImages(
                    class1: class1,
                    class2: class2,
                    basePath: resourceURL.path
                )

                // 一時ディレクトリのパスを取得
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(OvOClassifier.tempBaseDirName)
                let tempClass1Dir = tempDir.appendingPathComponent(class1)
                let tempClass2Dir = tempDir.appendingPathComponent(class2)

                // 一時ディレクトリ内の画像枚数を確認
                let tempClass1Files = try FileManager.default.contentsOfDirectory(
                    at: tempClass1Dir,
                    includingPropertiesForKeys: nil
                )
                .filter {
                    $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" || $0
                        .pathExtension.lowercased() == "png"
                }

                let tempClass2Files = try FileManager.default.contentsOfDirectory(
                    at: tempClass2Dir,
                    includingPropertiesForKeys: nil
                )
                .filter {
                    $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" || $0
                        .pathExtension.lowercased() == "png"
                }

                // 画像枚数が一致することを確認
                XCTAssertEqual(
                    tempClass1Files.count,
                    class1Count,
                    "クラス [\(class1)] の画像枚数が一致しません。期待値: \(class1Count), 実際: \(tempClass1Files.count)"
                )
                XCTAssertEqual(
                    tempClass2Files.count,
                    class2Count,
                    "クラス [\(class2)] の画像枚数が一致しません。期待値: \(class2Count), 実際: \(tempClass2Files.count)"
                )
                XCTAssertEqual(
                    tempClass1Files.count,
                    tempClass2Files.count,
                    "クラス [\(class1)] と [\(class2)] の画像枚数が一致しません。"
                )
            }
        }
    }

    /// 生成されるmlmodelファイルの数がクラスの組み合わせの数と一致することを確認する
    func testModelFileCountMatchesClassCombinations() throws {
        guard let result = trainingResult else {
            XCTFail("訓練結果がnilです")
            throw TestError.trainingFailed
        }

        // リソースディレクトリからクラスラベルの一覧を取得
        let resourceURL = URL(fileURLWithPath: classifier.resourcesDirectoryPath)
        let classLabels = try FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter(\.hasDirectoryPath)
        .map(\.lastPathComponent)
        .sorted()

        // クラスの組み合わせの数を計算（nC2 = n * (n-1) / 2）
        let expectedCombinationCount = (classLabels.count * (classLabels.count - 1)) / 2

        // モデルファイルのディレクトリを取得
        let modelFileDir = URL(fileURLWithPath: result.metadata.trainedModelFilePath).deletingLastPathComponent()

        // 生成されたmlmodelファイルの数を取得
        let modelFiles = try FileManager.default.contentsOfDirectory(at: modelFileDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mlmodel" }

        // クラスの組み合わせの数とmlmodelファイルの数が一致することを確認
        XCTAssertEqual(
            modelFiles.count,
            expectedCombinationCount,
            """
            生成されたmlmodelファイルの数がクラスの組み合わせの数と一致しません。
            クラス数: \(classLabels.count)
            期待される組み合わせ数: \(expectedCombinationCount)
            生成されたmlmodelファイル数: \(modelFiles.count)
            クラスラベル: \(classLabels.joined(separator: ", "))
            """
        )

        // 各モデルファイル名が正しいクラスの組み合わせを含むことを確認
        for modelFile in modelFiles {
            let fileName = modelFile.lastPathComponent
            // ファイル名からクラス名を抽出（例: "TestModel_OvO_class1_vs_class2_v1.mlmodel"）
            let components = fileName.components(separatedBy: "_")
            guard components.count >= 5,
                  let vsIndex = components.firstIndex(of: "vs")
            else {
                XCTFail("モデルファイル名の形式が不正です: \(fileName)")
                continue
            }

            // クラス1の名前を抽出（vsの前の部分）
            let class1Components = components[2 ..< vsIndex]
            let class1 = class1Components.joined(separator: "_")

            // クラス2の名前を抽出（vsの後の部分、バージョン番号の前まで）
            let class2Components = components[(vsIndex + 1) ..< (components.count - 1)]
            let class2 = class2Components.joined(separator: "_")

            // 抽出したクラス名が実際のクラスラベルのリストに含まれていることを確認
            XCTAssertTrue(
                classLabels.contains(class1) && classLabels.contains(class2),
                """
                モデルファイル名に含まれるクラス名が実際のクラスラベルのリストに存在しません。
                ファイル名: \(fileName)
                抽出されたクラス1: \(class1)
                抽出されたクラス2: \(class2)
                実際のクラスラベル: \(classLabels.joined(separator: ", "))
                """
            )
        }
    }

    private func getRandomImageURL(forClassLabel classLabel: String) throws -> URL {
        let resourceURL = URL(fileURLWithPath: classifier.resourcesDirectoryPath)
        let classLabelURL = resourceURL.appendingPathComponent(classLabel)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: classLabelURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            let message = "サブディレクトリ '\(classLabel)' が見つからないか、ディレクトリではありません: \(classLabelURL.path)"
            XCTFail(message)
            throw TestError.testResourceMissing
        }

        let validExtensions = ["jpg", "jpeg", "png"]
        let allFiles = try fileManager.contentsOfDirectory(
            at: classLabelURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { url in
            validExtensions.contains(url.pathExtension.lowercased())
        }

        guard !allFiles.isEmpty else {
            throw TestError.testResourceMissing
        }

        guard let randomFile = allFiles.randomElement() else {
            XCTFail("利用可能な画像ファイルが見つかりません")
            throw TestError.testResourceMissing
        }

        return randomFile
    }

    // 出力ディレクトリの連番を検証
    func testSequentialOutputDirectoryNumbering() async throws {
        // 1回目のモデル作成（setUpで実行済み）
        guard let firstResult = trainingResult else {
            XCTFail("1回目の訓練結果がnilです")
            throw TestError.trainingFailed
        }

        let firstModelFileDir = URL(fileURLWithPath: firstResult.metadata.trainedModelFilePath)
            .deletingLastPathComponent()

        // 2回目のモデル作成を実行
        let secondResult = await classifier.create(
            author: "TestAuthor",
            modelName: testModelName,
            version: "v1",
            modelParameters: modelParameters
        )

        guard let secondResult else {
            XCTFail("2回目の訓練結果がnilです")
            throw TestError.trainingFailed
        }

        let secondModelFileDir = URL(fileURLWithPath: secondResult.metadata.trainedModelFilePath)
            .deletingLastPathComponent()

        // 連番の検証
        let firstResultNumber = Int(firstModelFileDir.lastPathComponent.replacingOccurrences(
            of: "OvO_Result_",
            with: ""
        )) ?? 0
        let secondResultNumber = Int(secondModelFileDir.lastPathComponent.replacingOccurrences(
            of: "OvO_Result_",
            with: ""
        )) ?? 0
        XCTAssertEqual(
            secondResultNumber,
            firstResultNumber + 1,
            "2回目の出力ディレクトリの連番が期待値と一致しません。\n1回目: \(firstResultNumber)\n2回目: \(secondResultNumber)"
        )
    }
}
