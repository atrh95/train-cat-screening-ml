import CICConfusionMatrix
import CICInterface
import CICTrainingResult
import Foundation

/// 画像分類モデルのトレーニング結果を格納する構造体
public struct BinaryTrainingResult: TrainingResultProtocol {
    public let metadata: CICTrainingMetadata
    public let trainingMetrics: (accuracy: Double, errorRate: Double)
    public let validationMetrics: (accuracy: Double, errorRate: Double)
    public let confusionMatrix: CICBinaryConfusionMatrix?
    public let individualModelReport: CICIndividualModelReport

    public var modelOutputPath: String {
        URL(fileURLWithPath: metadata.trainedModelFilePath).deletingLastPathComponent().path
    }

    public init(
        metadata: CICTrainingMetadata,
        trainingMetrics: (accuracy: Double, errorRate: Double),
        validationMetrics: (accuracy: Double, errorRate: Double),
        confusionMatrix: CICBinaryConfusionMatrix?,
        individualModelReport: CICIndividualModelReport
    ) {
        self.metadata = metadata
        self.trainingMetrics = trainingMetrics
        self.validationMetrics = validationMetrics
        self.confusionMatrix = confusionMatrix
        self.individualModelReport = individualModelReport
    }

    public func saveLog(
        modelAuthor: String,
        modelName: String,
        modelVersion: String
    ) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let generatedDateString = dateFormatter.string(from: Date())

        let trainingAccStr = String(format: "%.2f", trainingMetrics.accuracy)
        let validationAccStr = String(format: "%.2f", validationMetrics.accuracy)
        let trainingErrStr = String(format: "%.2f", trainingMetrics.errorRate * 100)
        let validationErrStr = String(format: "%.2f", validationMetrics.errorRate * 100)
        let durationStr = String(format: "%.2f", metadata.trainingDurationInSeconds)

        var markdownText = """
        # モデルトレーニング情報: \(modelName)

        ## モデル詳細
        モデル名           : \(modelName)
        ファイル生成日時   : \(generatedDateString)
        最大反復回数     : \(metadata.maxIterations)
        データ拡張       : \(metadata.dataAugmentationDescription)
        特徴抽出器       : \(metadata.featureExtractorDescription)

        ## トレーニング設定
        使用されたクラスラベル : \(metadata.detectedClassLabelsList.joined(separator: ", "))

        ## パフォーマンス指標 (全体)
        トレーニング所要時間: \(durationStr) 秒
        トレーニング誤分類率 (学習時) : \(trainingErrStr)%
        訓練データ正解率 (学習時) : \(trainingAccStr)%
        検証データ正解率 (学習時自動検証) : \(validationAccStr)%
        検証誤分類率 (学習時自動検証) : \(validationErrStr)%
        """

        if let confusionMatrix {
            markdownText += """
            ## 性能指標
            - 再現率 (Recall)    : \(String(format: "%.1f%%", confusionMatrix.recall * 100.0))
            - 適合率 (Precision) : \(String(format: "%.1f%%", confusionMatrix.precision * 100.0))
            - F1スコア          : \(String(format: "%.3f", confusionMatrix.f1Score))
            """
        }

        markdownText += """

        ## 個別モデルの性能指標
        \(individualModelReport.generateMarkdownReport())

        ## モデルメタデータ
        作成者            : \(modelAuthor)
        バージョン          : \(modelVersion)
        """

        let outputDir = URL(fileURLWithPath: metadata.trainedModelFilePath).deletingLastPathComponent()
        let textFileName = "Binary_Run_Report_\(modelVersion).md"
        let textFilePath = outputDir.appendingPathComponent(textFileName).path

        do {
            try markdownText.write(toFile: textFilePath, atomically: true, encoding: String.Encoding.utf8)
            print("✅ [\(modelName)] モデル情報をMarkdownファイルに保存しました: \(textFilePath)")
        } catch {
            print("❌ [\(modelName)] Markdownファイルの書き込みに失敗しました: \(error.localizedDescription)")
            print("--- [\(modelName)] モデル情報 (Markdown) ---:")
            print(markdownText)
            print("--- ここまで --- ")
        }
    }
}
