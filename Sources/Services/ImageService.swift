import Foundation

/// 配图服务 - 参考百词斩风格，使用 Unsplash 或 Pexels
final class ImageService {
    static let shared = ImageService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    /// 获取单词配图 URL
    func fetchImage(for word: String) async throws -> String {
        // 使用 Unsplash Source API（免费，无需 key 可用）
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        let urlStr = "https://source.unsplash.com/400x300/?\(encoded),vocabulary,education"
        return urlStr
    }

    /// 下载图片数据
    func downloadImage(from urlString: String) async throws -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let (data, response) = try await session.data(from: url)
        guard let httpResp = response as? HTTPURLResponse,
              httpResp.statusCode == 200 else { return nil }
        return data
    }
}
