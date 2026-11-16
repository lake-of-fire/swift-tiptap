import Foundation

/// Navigation policy for the local writing page. Subresource loading is
/// separately restricted by the bundled page's Content Security Policy.
struct EditorResourcePolicy {
    let editorPageURL: URL

    func allowsNavigation(to url: URL?, sourceIsMainFrame: Bool, targetIsMainFrame: Bool) -> Bool {
        guard sourceIsMainFrame, targetIsMainFrame,
              let url,
              let destination = localPageComponents(url),
              let expected = localPageComponents(editorPageURL) else { return false }
        // A fragment stays within the same editor document. Even another
        // bundled file is not an allowed page, and query strings are refused.
        return destination == expected
    }

    private func localPageComponents(_ url: URL) -> URLComponents? {
        // Validate the original components first: standardizedFileURL may drop
        // a query or normalize a localhost authority away.
        guard url.isFileURL,
              let supplied = URLComponents(url: url, resolvingAgainstBaseURL: true),
              supplied.host?.isEmpty != false,
              supplied.user == nil, supplied.password == nil,
              supplied.port == nil, supplied.query == nil,
              var components = URLComponents(url: url.standardizedFileURL, resolvingAgainstBaseURL: true)
        else { return nil }
        components.fragment = nil
        return components
    }
}
