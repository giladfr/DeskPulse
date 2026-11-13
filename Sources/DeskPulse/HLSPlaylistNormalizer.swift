@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Hands AVPlayer each HLS playlist with every address made absolute and stable.
/// Some servers (CNN's) add a `pb_type` tag to segment addresses at random, so a
/// segment's address changes from one playlist read to the next; Apple's player takes
/// that as a broken stream and stops with error -12312. Playlists are fetched here
/// under a private scheme; segments still load straight from the server.
final class HLSPlaylistNormalizer: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "deskpulse-hls"
    let queue = DispatchQueue(label: "DeskPulse.HLSPlaylistNormalizer")

    /// The address to give AVPlayer for a playlist, so its reads come through here.
    static func playerURL(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url ?? url
    }

    static func realURL(for url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    /// Makes every address absolute, sends nested playlists back through here, and
    /// drops the query items that vary between reads.
    static func normalize(playlist: String, baseURL: URL) -> String {
        func resolve(_ reference: String) -> String {
            guard let absolute = URL(string: reference, relativeTo: baseURL)?.absoluteURL,
                  var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false)
            else { return reference }
            components.queryItems = components.queryItems?.filter { $0.name != "pb_type" }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            guard let stable = components.url else { return reference }
            return stable.path.hasSuffix(".m3u8") ? playerURL(for: stable).absoluteString : stable.absoluteString
        }
        return playlist
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { return line }
                if !line.hasPrefix("#") { return resolve(line) }
                // Keys, init segments and alternate renditions name addresses in URI="…".
                guard let start = line.range(of: "URI=\""),
                      let end = line[start.upperBound...].firstIndex(of: "\"")
                else { return line }
                return line.replacingCharacters(
                    in: start.upperBound..<end,
                    with: resolve(String(line[start.upperBound..<end]))
                )
            }
            .joined(separator: "\n")
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, let real = Self.realURL(for: url) else { return false }
        var request = URLRequest(url: real, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("AppleCoreMedia/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8)
            else {
                loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            let base = response?.url ?? real
            let body = Data(Self.normalize(playlist: text, baseURL: base).utf8)
            loadingRequest.contentInformationRequest?.contentType = UTType.m3uPlaylist.identifier
            loadingRequest.contentInformationRequest?.contentLength = Int64(body.count)
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
            loadingRequest.dataRequest?.respond(with: body)
            loadingRequest.finishLoading()
        }.resume()
        return true
    }
}
