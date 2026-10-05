//
//  ArtworkService.swift
//  NiceLyricsX
//
//  专辑封面查询 —— 通过 iTunes Search API 反查封面图 URL。
//
//  为什么需要:
//  `PlaybackInfo.artworkURL` 一直是个"有字段没人填"的状态 —— 唯一填它的路径
//  是 MediaRemote 的 artwork token,而 MediaRemote 在 macOS 26 上已被禁用,
//  所以菜单栏面板 / 桌面歌词永远拿不到封面。
//
//  iTunes Search API 是公开、免鉴权、无需登录的:
//    GET https://itunes.apple.com/search?term={title} {artist}&entity=song&limit=5
//  返回的 `artworkUrl100` 把 `100x100bb` 换成 `600x600bb` 就是高清封面。
//
//  失败(网络不通 / 搜不到)一律返回 nil —— 封面是锦上添花,不能影响歌词主流程。
//

import Foundation
import OSLog

public actor ArtworkService {

    public static let shared = ArtworkService()

    private let session: URLSession
    private let logger = Logger(subsystem: "com.local.NiceLyricsX", category: "Artwork")

    /// 进程内缓存 —— key 是 "title|artist"。命中后不再发请求。
    private var cache: [String: URL?] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 查询封面 URL。返回 `nil` 表示搜不到 / 请求失败。
    public func artworkURL(title: String, artist: String) async -> URL? {
        let key = Self.cacheKey(title: title, artist: artist)
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] { return cached }

        guard let request = Self.makeSearchRequest(title: title, artist: artist) else {
            cache[key] = URL?.none
            return nil
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                cache[key] = URL?.none
                return nil
            }
            let url = try Self.artworkURL(fromSearchResponse: data)
            cache[key] = url
            return url
        } catch {
            logger.debug("封面查询失败: \(error.localizedDescription, privacy: .public)")
            cache[key] = URL?.none
            return nil
        }
    }

    public func clear() {
        cache.removeAll()
    }

    // MARK: - 纯函数(可单测)

    static func cacheKey(title: String, artist: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return "\(t.lowercased())|\(a.lowercased())"
    }

    static func makeSearchRequest(title: String, artist: String) -> URLRequest? {
        // 曲名是必需项 —— 只拿艺人名去搜会返回一堆不相干的歌,封面就是错的
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let term = [trimmedTitle, artist.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        return request
    }

    /// 从 iTunes Search 响应里取第一条结果的封面,并升级到 600x600。
    static func artworkURL(fromSearchResponse data: Data) throws -> URL? {
        let envelope = try JSONDecoder().decode(SearchResponse.self, from: data)
        for result in envelope.results {
            if let upgraded = upgradeArtworkURL(result.artworkUrl100) {
                return upgraded
            }
        }
        return nil
    }

    /// `.../100x100bb.jpg` → `.../600x600bb.jpg`。
    /// 用正则替换,而不是硬编码 `100x100bb`,因为 Apple 的尺寸后缀不止一种。
    static func upgradeArtworkURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let upgraded = raw.replacingOccurrences(
            of: #"/\d+x\d+bb\."#,
            with: "/600x600bb.",
            options: .regularExpression
        )
        return URL(string: upgraded)
    }
}

// MARK: - 响应模型

extension ArtworkService {
    struct SearchResponse: Decodable {
        let resultCount: Int
        let results: [Item]

        struct Item: Decodable {
            let trackName: String?
            let artistName: String?
            let artworkUrl100: String?
        }
    }
}
