import Foundation
import CmdsCore

/// The SEO report in the app's language (the report tab); the API, CLI and MCP keep `SEOText.english`.
extension SEOText {
    static let localized = SEOText(message: { message in
        switch message {
        case .httpStatus(let status): return String(localized: "the page answered HTTP \(status)", comment: "SEO report")
        case .titleMissing: return String(localized: "no <title>", comment: "SEO report")
        case .titleLength(let characters, let width, let range, let title):
            return String(localized: "\(characters) characters, width \(width) (aim for \(range.lowerBound)–\(range.upperBound); wide characters count 2): \(title)", comment: "SEO report")
        case .titleOK(let characters, let title): return String(localized: "\(characters) characters: \(title)", comment: "SEO report")
        case .descriptionMissing: return String(localized: "no <meta name=\"description\">", comment: "SEO report")
        case .descriptionLength(let characters, let width, let range):
            return String(localized: "\(characters) characters, width \(width) (aim for \(range.lowerBound)–\(range.upperBound); wide characters count 2)", comment: "SEO report")
        case .descriptionOK(let characters): return String(localized: "\(characters) characters", comment: "SEO report")
        case .h1Missing: return String(localized: "no <h1>", comment: "SEO report")
        case .h1OK(let text): return String(localized: "one <h1>: \(text)", comment: "SEO report")
        case .h1Many(let count): return String(localized: "\(count) <h1> headings (one is usual)", comment: "SEO report")
        case .headingsSkipped(let skips): return String(localized: "heading levels skipped: \(skips)", comment: "SEO report")
        case .headingsOK(let count): return String(localized: "\(count) headings in order", comment: "SEO report")
        case .robotsNoindex(let robots):
            return String(localized: "<meta name=\"robots\"> asks search engines not to index the page (\(robots))", comment: "SEO report")
        case .robotsNofollow(let robots):
            return String(localized: "<meta name=\"robots\"> asks not to follow the links (\(robots))", comment: "SEO report")
        case .robotsIndexable(let robots):
            return robots.map { String(localized: "indexable (\($0))", comment: "SEO report") }
                ?? String(localized: "indexable (no robots meta tag)", comment: "SEO report")
        case .robotsTxtDisallowsAll: return String(localized: "robots.txt disallows the whole site for every crawler", comment: "SEO report")
        case .robotsTxtSitemaps(let count):
            return count == 1 ? String(localized: "robots.txt names a sitemap", comment: "SEO report")
                : String(localized: "robots.txt names \(count) sitemaps", comment: "SEO report")
        case .robotsTxtNoSitemap: return String(localized: "robots.txt has no Sitemap: line", comment: "SEO report")
        case .robotsTxtMissing: return String(localized: "no robots.txt (everything may be crawled)", comment: "SEO report")
        case .canonicalOtherHost(let canonical): return String(localized: "points to another host: \(canonical)", comment: "SEO report")
        case .canonicalMissing: return String(localized: "no <link rel=\"canonical\">", comment: "SEO report")
        case .langMissing: return String(localized: "no lang attribute on <html>", comment: "SEO report")
        case .viewportMissing: return String(localized: "no <meta name=\"viewport\"> (the page is not set up for phones)", comment: "SEO report")
        case .openGraphOK: return String(localized: "og:title, og:description and og:image set", comment: "SEO report")
        case .openGraphMissing(let keys): return String(localized: "missing \(keys) (link previews)", comment: "SEO report")
        case .twitterCardMissing: return String(localized: "no twitter:card", comment: "SEO report")
        case .altMissing(let missing, let images, let examples):
            let base = String(localized: "\(missing) of \(images) images without alt", comment: "SEO report")
            return examples.isEmpty ? base : base + ": " + examples
        case .altOK(let images): return String(localized: "all \(images) images have alt", comment: "SEO report")
        case .linksEmpty(let count): return String(localized: "\(count) links without text or label", comment: "SEO report")
        case .structuredDataInvalid(let count):
            return count == 1 ? String(localized: "a JSON-LD block is not valid JSON", comment: "SEO report")
                : String(localized: "\(count) JSON-LD blocks are not valid JSON", comment: "SEO report")
        case .structuredDataMissing: return String(localized: "no JSON-LD structured data", comment: "SEO report")
        case .httpOnly: return String(localized: "served over http, not https", comment: "SEO report")
        case .mixedContent(let count): return String(localized: "\(count) http: resources on an https page", comment: "SEO report")
        case .thinContent(let words): return String(localized: "\(words) words of text (thin pages rank poorly)", comment: "SEO report")
        case .faviconMissing: return String(localized: "no <link rel=\"icon\">", comment: "SEO report")
        case .charsetMissing: return String(localized: "no <meta charset>", comment: "SEO report")
        case .value(let value): return value
        case .linkCounts(let total, let inside, let outside, let nofollow):
            return String(localized: "\(total) (\(inside) internal, \(outside) external, \(nofollow) nofollow)", comment: "SEO report")
        case .imageCounts(let total, let withoutAlt): return String(localized: "\(total) (\(withoutAlt) without alt)", comment: "SEO report")
        }
    }, label: { label in
        switch label {
        case .report: return String(localized: "SEO Report")
        case .problems: return String(localized: "Problems", comment: "SEO report")
        case .warnings: return String(localized: "Warnings", comment: "SEO report")
        case .notes: return String(localized: "Notes", comment: "SEO report")
        case .passed: return String(localized: "Passed", comment: "SEO report")
        case .page: return String(localized: "Page", comment: "SEO report")
        case .title: return String(localized: "Title", comment: "SEO report")
        case .description: return String(localized: "Description", comment: "SEO report")
        case .language: return String(localized: "Language", comment: "SEO report")
        case .structuredData: return String(localized: "Structured data", comment: "SEO report")
        case .links: return String(localized: "Links", comment: "SEO report")
        case .images: return String(localized: "Images", comment: "SEO report")
        case .words: return String(localized: "Words", comment: "SEO report")
        case .headings: return String(localized: "Headings", comment: "SEO report")
        }
    })
}
