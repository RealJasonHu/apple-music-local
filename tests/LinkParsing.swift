import Foundation
@main struct LinkParsingTests {
    static func main() {
        let one = "https://music.apple.com/us/album/test/123?i=456"
        let result = DownloadModel.parseLinks(one + "\n" + one + "&ls=1\nhttps://music.apple.com/cn/playlist/test/pl.123\ninvalid")
        precondition(result.links.count == 2 && result.duplicates == 1 && result.rejected == 1)
        for invalid in ["https://music.apple.com.attacker.test/us/album/test/123", "http://music.apple.com/us/song/123", "https://music.apple.com/us/artist/example/123", "# Netscape HTTP Cookie File", "https://music.apple.com/library/playlist/123", "https://example.com"] {
            precondition(DownloadModel.parseLinks(invalid).links.isEmpty)
        }
        precondition(DownloadModel.parseLinks("https://music.apple.com/cn/song/test/123，https://music.apple.com/us/album/test/456").links.count == 2)
        print("Link parsing: batching, deduplication, tracking cleanup, unsupported URLs, cookie guard PASS")
    }
}
