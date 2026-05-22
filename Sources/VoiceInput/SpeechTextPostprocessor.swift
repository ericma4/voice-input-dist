import Foundation

enum SpeechTextPostprocessor {
    static func removingChineseFillers(from text: String) -> String {
        var result = text

        result = result.replacingOccurrences(
            of: #"(?:嗯+|呃+|额+|呣+)"#,
            with: "",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"(^|[\s，,。！？!?；;：:、])(?:那个|这个)(?=[\s，,。！？!?；;：:、])"#,
            with: "$1",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"^[\s，,。！？!?；;：:、]*(?:啊+|呀+|诶+|欸+|哎+|唉+|呐+|哦+|喔+|噢+)[\s，,。！？!?；;：:、]*"#,
            with: "",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"(?:啊+|呀+|诶+|欸+|哎+|唉+|呐+|哦+|喔+|噢+)(?=\s*[，,。！？!?；;：:、]*\s*$)"#,
            with: "",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"([\s，,。！？!?；;：:、])(?:啊+|呀+|诶+|欸+|哎+|唉+|呐+|哦+|喔+|噢+)(?=[\s，,。！？!?；;：:、]|$)"#,
            with: "$1",
            options: .regularExpression
        )

        return normalizePunctuation(result)
    }

    private static func normalizePunctuation(_ text: String) -> String {
        var result = text

        result = result.replacingOccurrences(
            of: #"^[\s，,。！？!?；;：:、]+"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[，,、]{2,}"#,
            with: "，",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[。]{2,}"#,
            with: "。",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[！!]{2,}"#,
            with: "！",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[？?]{2,}"#,
            with: "？",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"([，,、；;：:])([。！？!?])"#,
            with: "$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+([，。！？；：、,.!?;:])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"([\p{Han}])\s+([\p{Han}])"#,
            with: "$1$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
