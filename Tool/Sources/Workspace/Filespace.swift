import Dependencies
import Environment
import Foundation
import GitIgnoreCheck
import SuggestionModel

public protocol FilespacePropertyKey {
    associatedtype Value
    static func createDefaultValue() -> Value
}

public final class FilespacePropertyValues {
    private var storage: [ObjectIdentifier: Any] = [:]

    @WorkspaceActor
    public subscript<K: FilespacePropertyKey>(_ key: K.Type) -> K.Value {
        get {
            if let value = storage[ObjectIdentifier(key)] as? K.Value {
                return value
            }
            let value = key.createDefaultValue()
            storage[ObjectIdentifier(key)] = value
            return value
        }
        set {
            storage[ObjectIdentifier(key)] = newValue
        }
    }
}

public struct FilespaceCodeMetadata: Equatable {
    public var uti: String?
    public var tabSize: Int?
    public var indentSize: Int?
    public var usesTabsForIndentation: Bool?

    init(
        uti: String? = nil,
        tabSize: Int? = nil,
        indentSize: Int? = nil,
        usesTabsForIndentation: Bool? = nil
    ) {
        self.uti = uti
        self.tabSize = tabSize
        self.indentSize = indentSize
        self.usesTabsForIndentation = usesTabsForIndentation
    }
}

@dynamicMemberLookup
public final class Filespace {
    struct GitIgnoreStatus {
        var isIgnored: Bool
        var checkTime: Date
        var isExpired: Bool {
            Environment.now().timeIntervalSince(checkTime) > 60 * 3
        }
    }

    // MARK: Metadata

    public let fileURL: URL
    public private(set) lazy var language: CodeLanguage = languageIdentifierFromFileURL(fileURL)
    public var codeMetadata: FilespaceCodeMetadata = .init()

    // MARK: Suggestions

    public private(set) var suggestionIndex: Int = 0
    public internal(set) var suggestions: [CodeSuggestion] = [] {
        didSet { refreshUpdateTime() }
    }

    public var presentingSuggestion: CodeSuggestion? {
        guard suggestions.endIndex > suggestionIndex, suggestionIndex >= 0 else { return nil }
        return suggestions[suggestionIndex]
    }

    // MARK: Life Cycle

    public var isExpired: Bool {
        Environment.now().timeIntervalSince(lastSuggestionUpdateTime) > 60 * 3
    }

    private(set) var lastSuggestionUpdateTime: Date = Environment.now()
    private var additionalProperties = FilespacePropertyValues()
    let fileSaveWatcher: FileSaveWatcher
    let onClose: (URL) -> Void

    // MARK: Git Ignore

    @WorkspaceActor
    private var gitIgnoreStatus: GitIgnoreStatus?
    @WorkspaceActor
    public var isGitIgnored: Bool {
        get async {
            @Dependency(\.gitIgnoredChecker) var gitIgnoredChecker
            @Dependency(\.date) var date

            if let gitIgnoreStatus = gitIgnoreStatus, !gitIgnoreStatus.isExpired {
                return gitIgnoreStatus.isIgnored
            }
            let isIgnored = await gitIgnoredChecker.checkIfGitIgnored(fileURL: fileURL)
            gitIgnoreStatus = .init(isIgnored: isIgnored, checkTime: date())
            return isIgnored
        }
    }

    // MARK: Methods

    deinit {
        onClose(fileURL)
    }

    init(
        fileURL: URL,
        onSave: @escaping (Filespace) -> Void,
        onClose: @escaping (URL) -> Void
    ) {
        self.fileURL = fileURL
        self.onClose = onClose
        fileSaveWatcher = .init(fileURL: fileURL)
        fileSaveWatcher.changeHandler = { [weak self] in
            guard let self else { return }
            onSave(self)
        }
    }

    @WorkspaceActor
    public subscript<K>(
        dynamicMember dynamicMember: WritableKeyPath<FilespacePropertyValues, K>
    ) -> K {
        get { additionalProperties[keyPath: dynamicMember] }
        set { additionalProperties[keyPath: dynamicMember] = newValue }
    }

    @WorkspaceActor
    public func reset() {
        suggestions = []
        suggestionIndex = 0
    }

    public func refreshUpdateTime() {
        lastSuggestionUpdateTime = Environment.now()
    }

    @WorkspaceActor
    public func setSuggestions(_ suggestions: [CodeSuggestion]) {
        self.suggestions = suggestions
        suggestionIndex = 0
    }

    @WorkspaceActor
    public func nextSuggestion() {
        suggestionIndex += 1
        if suggestionIndex >= suggestions.endIndex {
            suggestionIndex = 0
        }
    }

    @WorkspaceActor
    public func previousSuggestion() {
        suggestionIndex -= 1
        if suggestionIndex < 0 {
            suggestionIndex = suggestions.endIndex - 1
        }
    }
}

