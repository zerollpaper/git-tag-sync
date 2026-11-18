// Git Tag Sync：Git のリポジトリになっているフォルダに Finder の「Git」タグを付け、
// Git の管理から外れたフォルダからは外すアプリ。
//
// - `--run [--dry-run] [--quiet]` で起動されたとき（launchd から）：画面を出さずに同期する。
//   ログに書く行は標準出力（launchd のログ）に出し、結果を last-run.json に保存する。
//   launchd から zsh などを直接起動するとフルディスクアクセスが効かないが、このアプリが自分で探索すれば、
//   アプリに与えた許可で読める。
// - `--untag フォルダ [--dry-run]`：そのフォルダと中の「Git」タグを外す（uninstall.sh が使う）。
// - 引数なしで開いたとき（Finder などから）：前回の結果、タグ付きのフォルダ、除外するフォルダを画面に出す。
//
// 除外先は ~/Library/Application Support/Git Tag Sync/excludes.txt。実行時刻とログの場所は launchd の plist から読む。
import AppKit
import SwiftUI

let jobLabel = "local.git-tag-sync"
let home = FileManager.default.homeDirectoryForCurrentUser
let jobPlistURL = home.appendingPathComponent("Library/LaunchAgents/\(jobLabel).plist")
let appSupportURL = home.appendingPathComponent("Library/Application Support/Git Tag Sync")
let stateURL = appSupportURL.appendingPathComponent("last-run.json")
/// 除外先の一覧（1行に1フォルダ）。画面からも編集する
let excludesURL = appSupportURL.appendingPathComponent("excludes.txt")
let tagName = "Git"

/// アプリにある言語（正本は英語）
let supportedLanguages = ["en", "ja"]
/// 言語の設定を保存するキー（このアプリの UserDefaults。空なら macOS の設定に合わせる）
let languageDefaultsKey = "Language"

/// 画面の言語。アプリで選んだ言語があればそれ、なければ macOS の言語設定とアプリにある訳から決める。
var uiLanguage: String {
  if let chosen = UserDefaults.standard.string(forKey: languageDefaultsKey), supportedLanguages.contains(chosen) {
    return chosen
  }
  return Bundle.main.preferredLocalizations.first ?? "en"
}
var uiLocale: Locale { Locale(identifier: uiLanguage) }

/// 言語ごとの訳の入った Bundle（en.lproj などのフォルダ）。見つからなければ本体。
private var languageBundles: [String: Bundle] = [:]
func languageBundle(_ language: String) -> Bundle {
  if let cached = languageBundles[language] { return cached }
  let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
  languageBundles[language] = bundle
  return bundle
}

/// 画面などに出す文を引く。正本は英語で、訳は Resources/<言語>.lproj/Localizable.strings にある
/// （訳の漏れは tools/check-strings.py で調べる）。埋め込みは %@・%d（順番を変えるときは %1$@ など）。
func L(_ key: String, _ args: CVarArg...) -> String {
  let format = languageBundle(uiLanguage).localizedString(forKey: key, value: key, table: nil)
  return args.isEmpty ? format : String(format: format, locale: uiLocale, arguments: args)
}

/// 1回の実行の結果。
struct RunRecord: Codable {
  var start: Date
  var end: Date
  var exitCode: Int32
  var dryRun: Bool
  var keep: Int
  var added: [String]
  var removed: [String]
  var warnings: [String]
  /// この回のログ（そのまま）
  var log: String
  /// 読めない場所があったか（フルディスクアクセスの案内を出す）。0.3.0 以前の記録にはない
  var permissionProblem: Bool?
}

/// 自動で同期する時刻の決め方
enum ScheduleMode: String, CaseIterable, Identifiable {
  case daily, interval, off
  var id: String { rawValue }
  var title: String {
    switch self {
    case .daily: return L("Every day")
    case .interval: return L("Every few hours")
    case .off: return L("Never")
    }
  }
}

/// 「一定の間隔」で選べる時間（24 を割り切れるもの）
let intervalChoices = [1, 2, 3, 4, 6, 8, 12]

/// launchd の plist の中身のうち、画面で扱うもの（実行する時刻・ログイン時の実行・ログの場所）。
/// 正本は plist そのもの。「N時間ごと」は、スリープ中に時刻を過ぎたときも起きたときに実行されるよう、
/// StartInterval（秒ごと）ではなく、時刻を並べた StartCalendarInterval で表す。
struct JobSettings: Equatable {
  var exists = false
  var mode: ScheduleMode = .daily
  /// 毎日：その時刻。一定の間隔：起点の時刻
  var hour = 10
  var minute = 0
  var intervalHours = 6
  var runAtLoad = false
  var logPath: String?
  /// plist にある時刻の指定そのまま（次回の計算に使う）
  var entries: [[String: Int]] = []

  /// 保存するときに StartCalendarInterval に入れる時刻（時・分）
  var plannedTimes: [(hour: Int, minute: Int)] {
    switch mode {
    case .off: return []
    case .daily: return [(hour, minute)]
    case .interval:
      return stride(from: 0, to: 24, by: intervalHours).map { ((hour + $0) % 24, minute) }.sorted { $0.hour < $1.hour }
    }
  }

  static func == (a: JobSettings, b: JobSettings) -> Bool {
    a.exists == b.exists && a.mode == b.mode && a.hour == b.hour && a.minute == b.minute
      && a.intervalHours == b.intervalHours && a.runAtLoad == b.runAtLoad && a.logPath == b.logPath && a.entries == b.entries
  }

  static func load() -> JobSettings {
    guard let data = try? Data(contentsOf: jobPlistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return JobSettings() }
    var s = JobSettings(exists: true)
    s.logPath = plist["StandardOutPath"] as? String
    s.runAtLoad = plist["RunAtLoad"] as? Bool ?? false
    if let one = plist["StartCalendarInterval"] as? [String: Int] { s.entries = [one] }
    if let many = plist["StartCalendarInterval"] as? [[String: Int]] { s.entries = many }
    let times = s.entries.compactMap { e -> (Int, Int)? in
      guard let h = e["Hour"], e.keys.allSatisfy({ $0 == "Hour" || $0 == "Minute" }) else { return nil }
      return (h, e["Minute"] ?? 0)
    }.sorted { $0.0 < $1.0 }
    if s.entries.isEmpty {
      s.mode = .off
    } else if times.count == 1 {
      (s.mode, s.hour, s.minute) = (.daily, times[0].0, times[0].1)
    } else if times.count == s.entries.count, 24 % times.count == 0,
              Set(times.map(\.1)).count == 1,
              zip(times, times.dropFirst()).allSatisfy({ $1.0 - $0.0 == 24 / times.count }) {
      (s.mode, s.intervalHours, s.hour, s.minute) = (.interval, 24 / times.count, times[0].0, times[0].1)
    } else if let first = times.first {
      // 手で書いた独自の時刻。画面では「毎日」の最初の時刻として見せる（保存すると置き換わる）
      (s.mode, s.hour, s.minute) = (.daily, first.0, first.1)
    }
    return s
  }

  /// 次に実行される日時（plist にある時刻の指定から計算する）
  func nextRun(after now: Date = Date()) -> Date? {
    entries.compactMap { e -> Date? in
      var c = DateComponents()
      c.month = e["Month"]; c.day = e["Day"]; c.weekday = e["Weekday"].map { $0 % 7 + 1 }
      c.hour = e["Hour"]; c.minute = e["Minute"] ?? 0
      return Calendar.current.nextDate(after: now, matching: c, matchingPolicy: .nextTime)
    }.min()
  }

  /// 画面に出す説明（例：「毎日 10:00」「6時間ごと（4:00・10:00・16:00・22:00）」）
  var summary: String {
    func t(_ h: Int, _ m: Int) -> String { String(format: "%d:%02d", h, m) }
    switch mode {
    case .off: return L("No automatic sync")
    case .daily: return L("Every day at %@", t(hour, minute))
    case .interval:
      let times = plannedTimes
      if times.count <= 6 {
        return L("Every %1$d hours (%2$@)", intervalHours, times.map { t($0.hour, $0.minute) }.joined(separator: L(", ")))
      }
      return intervalHours == 1 ? L("Every hour from %@", t(hour, minute))
        : L("Every %1$d hours from %2$@", intervalHours, t(hour, minute))
    }
  }

  /// 「N時間ごと」の選択肢の名前
  static func intervalTitle(_ hours: Int) -> String {
    hours == 1 ? L("Every hour") : L("Every %d hours", hours)
  }

  /// plist を書き換える（ほかの項目はそのまま残す）
  func write() throws {
    let data = try Data(contentsOf: jobPlistURL)
    guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
      throw NSError(domain: "GitTagSync", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Cannot read the launchd configuration file.")])
    }
    let times = plannedTimes.map { ["Hour": $0.hour, "Minute": $0.minute] }
    switch mode {
    case .off: plist.removeValue(forKey: "StartCalendarInterval")
    case .daily: plist["StartCalendarInterval"] = times[0]
    case .interval: plist["StartCalendarInterval"] = times
    }
    plist["RunAtLoad"] = runAtLoad
    let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try out.write(to: jobPlistURL, options: .atomic)
  }
}

// MARK: - 同期の本体

/// 終了コードを返す処理の出力先（launchd から動くときは標準出力＝ログ）
func writeOut(_ text: String) {
  FileHandle.standardOutput.write(text.data(using: .utf8)!)
}

func stamp(_ date: Date) -> String {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.dateFormat = "yyyy-MM-dd HH:mm:ss"
  return f.string(from: date)
}

/// 除外先の一覧を読む。ファイルがなければ、アプリに同梱した例（excludes.example.txt）から作る。
func loadExcludeList() -> [String] {
  ensureExcludesFile()
  let text = (try? String(contentsOf: excludesURL, encoding: .utf8)) ?? ""
  return text.components(separatedBy: "\n").compactMap(excludePath(fromLine:))
}

func ensureExcludesFile() {
  let fm = FileManager.default
  guard !fm.fileExists(atPath: excludesURL.path) else { return }
  try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
  if let example = Bundle.main.url(forResource: "excludes.example", withExtension: "txt") {
    try? fm.copyItem(at: example, to: excludesURL)
  } else {
    try? "~/Library\n".write(to: excludesURL, atomically: true, encoding: .utf8)
  }
}

/// excludes.txt の1行を絶対パスにする（空行・コメント・/ か ~ で始まらない行は nil）
func excludePath(fromLine raw: String) -> String? {
  let line = raw.trimmingCharacters(in: .whitespaces)
  guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
  var path = line
  if path == "~" || path.hasPrefix("~/") { path = home.path + path.dropFirst() }
  guard path.hasPrefix("/") else { return nil }
  return URL(fileURLWithPath: path).standardizedFileURL.path
}

func isInside(_ path: String, _ base: String) -> Bool {
  path == base || path.hasPrefix(base + "/")
}

/// 探しも、タグを付けも外しもしない場所か（ホームフォルダの外・ホームフォルダそのもの・除外先・. で始まるフォルダの中）
func isExcluded(_ path: String, _ excludes: [String]) -> Bool {
  guard path.hasPrefix(home.path + "/") else { return true }
  if excludes.contains(where: { isInside(path, $0) }) { return true }
  return path.dropFirst(home.path.count + 1).split(separator: "/").contains { $0.hasPrefix(".") }
}

/// 「Git」タグが付いているか。URL は値を覚えてしまうので、毎回作り直す
func hasTag(_ path: String) -> Bool {
  let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey])
  return values?.tagNames?.contains(tagName) ?? false
}

/// 「Git」タグを付ける・外す。ほかのタグはそのまま残す
func setTag(_ path: String, _ on: Bool) throws {
  let url = URL(fileURLWithPath: path)
  var names = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
  if on {
    guard !names.contains(tagName) else { return }
    names.append(tagName)
  } else {
    guard names.contains(tagName) else { return }
    names.removeAll { $0 == tagName }
  }
  try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
}

/// Spotlight で「Git」タグが付いているものを探す。失敗したら nil（そのときは何も変えずに止める）
func taggedPaths(in folder: String) -> [String]? {
  let result = runCommand("/usr/bin/mdfind", ["-0", "-onlyin", folder, "kMDItemUserTags == \"\(tagName)\""])
  guard result.status == 0 else { return nil }
  return result.output.split(separator: "\0").map(String.init).filter { $0.hasPrefix("/") }
}

/// ホームフォルダから、.git（フォルダでもファイルでもよい）のあるフォルダを探す。
/// .git の中と、除外先・. で始まるフォルダの中には入らない。シンボリックリンクはたどらない。
/// 速さのため、find と同じ OS の仕組み（fts）でたどり、ファイルの情報はほぼ取らない（Foundation の列挙だと数倍遅い）。
func findRepositories(excludes: [String]) -> (repos: [String], unreadable: [(path: String, permission: Bool)]) {
  var repos = Set<String>()
  var unreadable: [(path: String, permission: Bool)] = []
  let root = strdup(home.path)
  defer { free(root) }
  var roots: [UnsafeMutablePointer<CChar>?] = [root, nil]
  guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) else {
    return ([], [(home.path, false)])
  }
  defer { fts_close(fts) }
  while let entry = fts_read(fts) {
    let path = String(cString: entry.pointee.fts_path)
    let isGit = path.hasSuffix("/.git")
    switch Int32(entry.pointee.fts_info) {
    case FTS_D:
      if isGit {
        repos.insert(String(path.dropLast(5)))
        fts_set(fts, entry, FTS_SKIP)
      } else if path != home.path && isExcluded(path, excludes) {
        fts_set(fts, entry, FTS_SKIP)
      }
    case FTS_DNR, FTS_ERR:
      let code = entry.pointee.fts_errno
      unreadable.append((path, code == EPERM || code == EACCES))
    default:
      // ファイルの .git（サブモジュールや worktree）。シンボリックリンクの .git は数えない
      if isGit {
        var st = stat()
        if lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG { repos.insert(String(path.dropLast(5))) }
      }
    }
  }
  return (repos.sorted(), unreadable)
}

/// 同期する。タグを付け・外し、ログに書く行を out に渡し、結果を返す
func performSync(dryRun: Bool, quiet: Bool, out: (String) -> Void) -> RunRecord {
  let start = Date()
  var record = RunRecord(start: start, end: start, exitCode: 0, dryRun: dryRun, keep: 0,
                         added: [], removed: [], warnings: [], log: "", permissionProblem: false)
  var log = ""
  func emit(_ line: String) { log += line + "\n"; out(line) }
  func warn(_ line: String) { record.warnings.append(line); emit("WARNING: " + line) }

  let excludes = loadExcludeList()
  let scan = findRepositories(excludes: excludes)
  if !scan.unreadable.isEmpty {
    warn(L("Some folders could not be searched. The folders that could be checked are synced, but the sync is incomplete."))
    for item in scan.unreadable { warn(L("Could not read: %@", item.path)) }
    record.permissionProblem = scan.unreadable.contains { $0.permission }
  }
  // 外す候補を先に調べる。調べられなければ、何も変えずに止める
  guard let tagged = taggedPaths(in: home.path) else {
    emit("ERROR: " + L("Could not search for tagged folders with Spotlight (mdfind). Nothing was changed."))
    record.exitCode = 1; record.end = Date(); record.log = log
    return record
  }

  for repo in scan.repos where !isExcluded(repo, excludes) {
    if hasTag(repo) {
      record.keep += 1
      if !quiet { emit("KEEP  : \(repo)") }
      continue
    }
    do {
      if !dryRun { try setTag(repo, true) }
      record.added.append(repo)
      emit("ADD   : \(repo)")
    } catch {
      warn(L("Could not add the tag to %1$@: %2$@", repo, error.localizedDescription))
    }
  }

  let fm = FileManager.default
  for path in tagged where !isExcluded(path, excludes) {
    var isDir: ObjCBool = false
    let attributes = try? fm.attributesOfItem(atPath: path)
    guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink,
          fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
          fm.isReadableFile(atPath: path), fm.isExecutableFile(atPath: path) else { continue }
    // Spotlight の結果に頼らず、今 .git がないことを確かめ直す（壊れたリンクの .git もあるとみなす）
    let gitPath = path + "/.git"
    guard (try? fm.attributesOfItem(atPath: gitPath)) == nil, hasTag(path) else { continue }
    do {
      if !dryRun { try setTag(path, false) }
      record.removed.append(path)
      emit("REMOVE: \(path)")
    } catch {
      warn(L("Could not remove the tag from %1$@: %2$@", path, error.localizedDescription))
    }
  }

  if dryRun { emit("DRY RUN: " + L("no tags were changed.")) }
  emit("SUMMARY -> KEEP: \(record.keep), ADD: \(record.added.count), REMOVE: \(record.removed.count)")
  // 探しきれなかったときは、成功扱いにしない
  record.exitCode = scan.unreadable.isEmpty ? 0 : 1
  record.end = Date()
  record.log = log
  return record
}

/// そのフォルダ自身と、その中で「Git」タグが付いているものからタグを外す。外した数を返す
func untagAll(in folder: String, dryRun: Bool = false, out: (String) -> Void = { _ in }) -> Result<Int, Error> {
  let target = URL(fileURLWithPath: folder).standardizedFileURL.path
  var isDir: ObjCBool = false
  guard isInside(target, home.path), FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
    return .failure(NSError(domain: "GitTagSync", code: 2, userInfo: [NSLocalizedDescriptionKey:
      L("Specify your home folder or a folder inside it: %@", folder)]))
  }
  guard let tagged = taggedPaths(in: target) else {
    return .failure(NSError(domain: "GitTagSync", code: 3, userInfo: [NSLocalizedDescriptionKey:
      L("Could not search for tagged folders with Spotlight (mdfind). Nothing was changed.")]))
  }
  var count = 0
  for path in [target] + tagged where isInside(path, target) && hasTag(path) {
    if !dryRun {
      do { try setTag(path, false) } catch { return .failure(error) }
    }
    out("UNTAG : \(path)")
    count += 1
  }
  if dryRun { out("DRY RUN: " + L("no tags were changed.")) }
  out("SUMMARY -> UNTAG: \(count)")
  return .success(count)
}

func saveRecord(_ record: RunRecord) {
  do {
    try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted]
    try encoder.encode(record).write(to: stateURL, options: .atomic)
  } catch {
    FileHandle.standardError.write((L("WARNING: Cannot save the result: %@", "\(error)") + "\n").data(using: .utf8)!)
  }
}

// MARK: - 画面を出さずに動くとき（launchd から・uninstall.sh から）

/// --run [--dry-run] [--quiet]：同期してログに書き、結果を保存する
func runFromCommandLine(_ args: [String]) -> Int32 {
  let start = Date()
  writeOut(L("=== %1$@ started %2$@", stamp(start), args.joined(separator: " ")) + "\n")
  let record = performSync(dryRun: args.contains("--dry-run"), quiet: args.contains("--quiet")) { writeOut($0 + "\n") }
  writeOut(L("=== %1$@ finished (exit code %2$d)", stamp(Date()), Int(record.exitCode)) + "\n")
  saveRecord(record)
  return record.exitCode
}

/// --untag フォルダ [--dry-run]：そのフォルダと中の「Git」タグを外す
func untagFromCommandLine(_ args: [String]) -> Int32 {
  guard let folder = args.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write((L("--untag needs a folder.") + "\n").data(using: .utf8)!)
    return 2
  }
  switch untagAll(in: folder, dryRun: args.contains("--dry-run"), out: { writeOut($0 + "\n") }) {
  case .success: return 0
  case .failure(let error):
    FileHandle.standardError.write(("ERROR: " + error.localizedDescription + "\n").data(using: .utf8)!)
    return 1
  }
}

// MARK: - 画面（Finder などから開いたとき）

/// コマンドを実行して、終了コードと標準出力を返す。
func runCommand(_ path: String, _ args: [String], environment: [String: String]? = nil) -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = args
  if let environment { process.environment = environment }
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  do {
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  } catch {
    return (-1, "\(error)")
  }
}

final class Model: ObservableObject {
  @Published var record: RunRecord?
  @Published var settings = JobSettings.load()
  @Published var syncing = false
  @Published var busy = false
  @Published var message: String?
  @Published var excludes: [String] = []
  @Published var tagged: [String] = []
  @Published var taggedLoading = false
  /// アプリで選んだ言語（空なら macOS の設定に合わせる）。変えると画面がその場で描き直される
  @Published var language = UserDefaults.standard.string(forKey: languageDefaultsKey) ?? "" {
    didSet {
      if language.isEmpty {
        UserDefaults.standard.removeObject(forKey: languageDefaultsKey)
      } else {
        UserDefaults.standard.set(language, forKey: languageDefaultsKey)
      }
      onLanguageChange?()
    }
  }
  var onLanguageChange: (() -> Void)?
  private var timer: Timer?

  init() { load() }

  func load() {
    settings = JobSettings.load()
    loadExcludes()
    loadTagged()
    guard let data = try? Data(contentsOf: stateURL) else { record = nil; return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    record = try? decoder.decode(RunRecord.self, from: data)
  }

  func loadExcludes() {
    excludes = loadExcludeList()
  }

  /// 今「Git」タグが付いているもの（Spotlight で探す）
  func loadTagged() {
    taggedLoading = true
    DispatchQueue.global().async {
      let result = runCommand("/usr/bin/mdfind", ["-onlyin", home.path, "kMDItemUserTags == \"Git\""])
      let paths = result.output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }.sorted()
      DispatchQueue.main.async { self.tagged = paths; self.taggedLoading = false }
    }
  }

  /// 除外できるか。できなければ理由を返す。
  func exclusionProblem(_ path: String) -> String? {
    if !isInside(path, home.path) || path == home.path { return L("Choose a folder inside your home folder.") }
    if path.dropFirst(home.path.count + 1).split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
      return L("Folders whose names start with “.” are always excluded.")
    }
    if let base = excludes.first(where: { isInside(path, $0) }) {
      return L("Already excluded (%@).", shortPath(base))
    }
    return nil
  }

  /// 除外に追加し、そのフォルダと中の「Git」タグを外す。
  func addExclusion(_ rawPath: String) {
    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    if let problem = exclusionProblem(path) { message = problem; return }
    ensureExcludesFile()
    var text = (try? String(contentsOf: excludesURL, encoding: .utf8)) ?? ""
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    text += shortPath(path) + "\n"
    do {
      try text.write(to: excludesURL, atomically: true, encoding: .utf8)
    } catch {
      message = L("Could not write excludes.txt: %@", error.localizedDescription)
      return
    }
    loadExcludes()
    busy = true
    message = L("Removing tags inside %@…", shortPath(path))
    DispatchQueue.global().async {
      let result = untagAll(in: path)
      DispatchQueue.main.async {
        self.busy = false
        switch result {
        case .success(let count):
          self.message = L("Excluded %1$@ and removed %2$@ “Git” tags.", shortPath(path), "\(count)")
        case .failure(let error):
          self.message = L("Excluded the folder, but could not remove the tags: %@", error.localizedDescription)
        }
        self.loadTagged()
      }
    }
  }

  /// 除外から外す。excludes.txt の、その行だけを消す（コメントなどは残す）。
  func removeExclusion(_ path: String) {
    let text = (try? String(contentsOf: excludesURL, encoding: .utf8)) ?? ""
    let kept = text.components(separatedBy: "\n").filter { excludePath(fromLine: $0) != path }
    do {
      try kept.joined(separator: "\n").write(to: excludesURL, atomically: true, encoding: .utf8)
    } catch {
      message = L("Could not write excludes.txt: %@", error.localizedDescription)
      return
    }
    loadExcludes()
    message = L("Stopped excluding %@. Repositories inside will be tagged at the next sync (or when you click Sync Now).", shortPath(path))
  }

  func chooseExclusions() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.directoryURL = home
    panel.prompt = L("Exclude")
    panel.message = L("Choose folders to exclude. The “Git” tag is removed from them and from everything inside.")
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { addExclusion(url.path) }
  }

  /// launchd のジョブを今すぐ動かし、結果が書き換わるまで待つ。
  func syncNow() {
    message = nil
    let started = Date()
    let kick = runCommand("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(jobLabel)"])
    guard kick.status == 0 else {
      message = L("Could not start the launchd job %@. Run install.sh again.", jobLabel)
      return
    }
    syncing = true
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
      guard let self else { t.invalidate(); return }
      let modified = (try? stateURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, modified > started {
        t.invalidate(); self.syncing = false; self.load()
      } else if Date().timeIntervalSince(started) > 15 * 60 {
        t.invalidate(); self.syncing = false
        self.message = L("The sync did not finish within 15 minutes. Check the log.")
      }
    }
  }

  /// 自動で同期する時刻の設定を保存し、launchd に読み込み直させる。
  func applySchedule(_ new: JobSettings) {
    let domain = "gui/\(getuid())"
    if runCommand("/bin/launchctl", ["print", "\(domain)/\(jobLabel)"]).output.contains("state = running") {
      message = L("A sync is running. Save again after it finishes.")
      return
    }
    busy = true
    message = L("Saving the schedule…")
    DispatchQueue.global().async {
      var problem: String?
      do {
        try new.write()
        _ = runCommand("/bin/launchctl", ["bootout", "\(domain)/\(jobLabel)"])
        for _ in 0..<20 {
          if runCommand("/bin/launchctl", ["print", "\(domain)/\(jobLabel)"]).status != 0 { break }
          Thread.sleep(forTimeInterval: 0.5)
        }
        let boot = runCommand("/bin/launchctl", ["bootstrap", domain, jobPlistURL.path])
        if boot.status != 0 {
          problem = L("Could not load the job into launchd: %@", boot.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      } catch {
        problem = L("Could not save: %@", error.localizedDescription)
      }
      DispatchQueue.main.async {
        self.busy = false
        self.settings = JobSettings.load()
        let s = self.settings
        let done: String
        switch (s.mode == .off, s.runAtLoad) {
        case (true, false): done = L("Automatic sync is now off.")
        case (true, true): done = L("Automatic sync is now off. It still syncs at login.")
        case (false, false): done = L("Automatic sync: %@.", s.summary)
        case (false, true): done = L("Automatic sync: %@. Also syncs at login.", s.summary)
        }
        self.message = problem ?? done
      }
    }
  }

  func openFullLog() {
    let path = settings.logPath ?? home.appendingPathComponent("Library/Logs/git-tag-sync.log").path
    NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                            configuration: NSWorkspace.OpenConfiguration())
  }
}

func displayDate(_ date: Date) -> String {
  let cal = Calendar.current
  let clock = DateFormatter()
  clock.dateFormat = "H:mm"
  let time = clock.string(from: date)
  if cal.isDateInToday(date) { return L("Today %@", time) }
  if cal.isDateInYesterday(date) { return L("Yesterday %@", time) }
  if cal.isDateInTomorrow(date) { return L("Tomorrow %@", time) }
  let day = DateFormatter()
  day.locale = uiLocale
  day.setLocalizedDateFormatFromTemplate("MMMdEEE")
  return "\(day.string(from: date)) \(time)"
}

func shortPath(_ path: String) -> String {
  let h = home.path
  return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
}

func revealInFinder(_ path: String) {
  NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

struct StatView: View {
  let title: String
  let value: Int
  let symbol: String
  let color: Color

  var body: some View {
    VStack(spacing: 4) {
      Image(systemName: symbol).font(.title2).foregroundStyle(value > 0 ? color : .secondary)
      Text("\(value)").font(.title.weight(.semibold)).monospacedDigit()
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}

/// フォルダ1行。左にアイコン、右に Finder で表示と（あれば）追加の操作。
struct PathRow: View {
  let path: String
  var symbol = "folder.fill"
  var tint: Color = .secondary
  var onExclude: (() -> Void)?
  var onRemove: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).foregroundStyle(tint)
      Text(shortPath(path)).lineLimit(1).truncationMode(.middle).help(path)
      Spacer()
      Button { revealInFinder(path) } label: { Image(systemName: "magnifyingglass") }
        .buttonStyle(.borderless).help(L("Show in Finder"))
      if let onExclude {
        Button(L("Exclude"), action: onExclude).controlSize(.small)
          .help(L("Exclude this folder and remove the “Git” tag inside it"))
      }
      if let onRemove {
        Button(action: onRemove) { Image(systemName: "minus.circle") }
          .buttonStyle(.borderless).help(L("Stop excluding"))
      }
    }
  }
}

struct ResultTab: View {
  @ObservedObject var model: Model

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let r = model.record {
          lastRun(r)
        } else {
          GroupBox {
            Text(L("No sync has run yet. Click Sync Now or wait for the next scheduled run."))
              .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  func lastRun(_ r: RunRecord) -> some View {
    let failed = r.exitCode != 0
    let warned = !r.warnings.isEmpty
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Image(systemName: failed ? "xmark.octagon.fill" : warned ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundStyle(failed ? .red : warned ? .orange : .green)
          Text(failed ? L("The last sync did not finish") : warned ? L("The last sync finished with warnings") : L("The last sync finished successfully"))
            .font(.headline)
          Spacer()
          Text(displayDate(r.end)).foregroundStyle(.secondary)
        }
        if r.dryRun {
          Text(L("This was a dry run (--dry-run), so no tags were changed.")).font(.callout).foregroundStyle(.secondary)
        }
        HStack {
          StatView(title: L("Unchanged"), value: r.keep, symbol: "tag.fill", color: .blue)
          StatView(title: L("Tagged"), value: r.added.count, symbol: "plus.circle.fill", color: .green)
          StatView(title: L("Untagged"), value: r.removed.count, symbol: "minus.circle.fill", color: .orange)
        }
      }
      .padding(6)
    }

    if !r.added.isEmpty || !r.removed.isEmpty {
      GroupBox(L("Changed folders")) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(r.added, id: \.self) { path in
            PathRow(path: path, symbol: "plus.circle.fill", tint: .green,
                    onExclude: model.excludes.contains(where: { isInside(path, $0) }) ? nil : { model.addExclusion(path) })
          }
          ForEach(r.removed, id: \.self) { PathRow(path: $0, symbol: "minus.circle.fill", tint: .orange) }
        }
        .padding(6)
      }
    }

    if r.permissionProblem == true || r.warnings.contains(where: { $0.contains("Operation not permitted") }) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "lock.fill").foregroundStyle(.orange)
        Text(L("Some folders could not be read. Git Tag Sync may not have Full Disk Access. Check that it is switched on; if it is, remove it from the list and add it again."))
          .font(.callout).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(L("Open Settings")) {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!)
        }
      }
    }

    if !r.warnings.isEmpty {
      GroupBox(L("Warnings (%d)", r.warnings.count)) {
        ScrollView {
          Text(r.warnings.joined(separator: "\n"))
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .frame(height: min(CGFloat(r.warnings.count) * 16 + 12, 120))
      }
    }

    DisclosureGroup(L("Log of this run")) {
      ScrollView {
        Text(r.log.isEmpty ? L("(no output)") : r.log)
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(6)
      }
      .frame(height: 140)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
  }
}

struct TaggedTab: View {
  @ObservedObject var model: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(L("Folders with the “Git” tag (%d)", model.tagged.filter { path in !model.excludes.contains(where: { isInside(path, $0) }) }.count)).font(.headline)
        if model.taggedLoading { ProgressView().controlSize(.small) }
        Spacer()
        Button { model.loadTagged() } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).help(L("Reload"))
      }
      // 除外したばかりのものは、Spotlight に反映されるまで残って見えるので出さない。
      List(model.tagged.filter { path in !model.excludes.contains(where: { isInside(path, $0) }) }, id: \.self) { path in
        PathRow(path: path, symbol: "tag.fill", tint: .blue, onExclude: { model.addExclusion(path) })
      }
      .listStyle(.inset(alternatesRowBackgrounds: true))
      Text(L("Found with Spotlight. Newly tagged folders may take a moment to appear."))
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct ExcludesTab: View {
  @ObservedObject var model: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      GroupBox {
        VStack(alignment: .leading, spacing: 4) {
          Label(L("Search scope: your whole home folder (~)"), systemImage: "magnifyingglass")
          Label(L("Always excluded: folders whose names start with “.” and everything inside (tools keep settings and caches there)"), systemImage: "eye.slash")
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(4)
      }
      HStack {
        Text(L("Excluded folders (%d)", model.excludes.count)).font(.headline)
        Spacer()
        Button(L("Add Folder…")) { model.chooseExclusions() }.disabled(model.busy)
      }
      List(model.excludes, id: \.self) { path in
        PathRow(path: path, symbol: "folder.badge.minus", tint: .secondary, onRemove: { model.removeExclusion(path) })
      }
      .listStyle(.inset(alternatesRowBackgrounds: true))
      HStack(alignment: .top) {
        Text(L("Excluding a folder removes the “Git” tag from it and from everything inside. After you stop excluding it, repositories inside are tagged at the next sync."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(L("Show excludes.txt")) { revealInFinder(excludesURL.path) }.controlSize(.small)
      }
    }
  }
}

struct ScheduleSheet: View {
  @ObservedObject var model: Model
  @State var draft: JobSettings
  @Environment(\.dismiss) private var dismiss

  /// 時・分を DatePicker で扱うための橋渡し
  var time: Binding<Date> {
    Binding(
      get: { Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date() },
      set: { date in
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        draft.hour = c.hour ?? 0
        draft.minute = c.minute ?? 0
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(L("Sync automatically")).font(.headline)
      Picker(L("Sync automatically"), selection: $draft.mode) {
        ForEach(ScheduleMode.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented).labelsHidden()

      Group {
        switch draft.mode {
        case .daily:
          DatePicker(L("Time"), selection: time, displayedComponents: .hourAndMinute)
        case .interval:
          Picker(L("Interval"), selection: $draft.intervalHours) {
            ForEach(intervalChoices, id: \.self) { Text(JobSettings.intervalTitle($0)).tag($0) }
          }
          DatePicker(L("Starting at"), selection: time, displayedComponents: .hourAndMinute)
        case .off:
          Text(L("Git Tag Sync does not sync automatically. You can always click Sync Now."))
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: 260, alignment: .leading)

      if draft.mode != .off {
        Label(draft.summary, systemImage: "clock").font(.callout).foregroundStyle(.secondary)
      }
      Toggle(L("Also sync at login"), isOn: $draft.runAtLoad)
      Text(L("If the Mac is asleep at a scheduled time, it syncs when the Mac wakes up. If you turn on “Also sync at login” and save, it also syncs right away."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(L("Save")) {
          model.applySchedule(draft)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draft == model.settings)
      }
    }
    .padding(20)
    .frame(width: 400)
  }
}

struct ContentView: View {
  @ObservedObject var model: Model
  @State private var showSchedule = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
        VStack(alignment: .leading, spacing: 2) {
          Text("Git Tag Sync").font(.title2.weight(.semibold))
          Text(L("Keeps the Finder “Git” tag on your Git repositories"))
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          Picker(L("Language"), selection: $model.language) {
            Text(L("System Setting")).tag("")
            Text("English").tag("en")
            Text("日本語").tag("ja")
          }
          .pickerStyle(.inline)
        } label: {
          Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Language"))
      }
      .id(model.language)

      TabView {
        ResultTab(model: model).padding(10).tabItem { Text(L("Last Run")) }
        TaggedTab(model: model).padding(10).tabItem { Text(L("Tagged Folders")) }
        ExcludesTab(model: model).padding(10).tabItem { Text(L("Excluded Folders")) }
      }

      if let message = model.message {
        HStack(spacing: 8) {
          if model.busy { ProgressView().controlSize(.small) } else { Image(systemName: "info.circle").foregroundStyle(.blue) }
          Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
      }

      HStack {
        if !model.settings.exists {
          Label(L("No scheduled sync (run install.sh)"), systemImage: "clock.badge.exclamationmark")
            .foregroundStyle(.orange)
        } else {
          Group {
            if let next = model.settings.nextRun() {
              Label(L("Next: %@", displayDate(next)), systemImage: "clock")
            } else {
              Label(L("No automatic sync"), systemImage: "pause.circle")
            }
          }
          .foregroundStyle(.secondary)
          .help(model.settings.runAtLoad ? L("%@, and at login", model.settings.summary) : model.settings.summary)
          Button(L("Change…")) { showSchedule = true }
            .controlSize(.small)
            .disabled(model.busy || model.syncing)
        }
        Spacer()
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
          Text("v\(version)").font(.caption).foregroundStyle(.tertiary)
        }
        Button(L("Open Full Log")) { model.openFullLog() }
        Button {
          model.syncNow()
        } label: {
          if model.syncing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Syncing…")) }
          } else {
            Text(L("Sync Now"))
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.syncing || model.busy)
      }
    }
    .padding(20)
    .frame(width: 600, height: 600)
    .sheet(isPresented: $showSchedule) { ScheduleSheet(model: model, draft: model.settings) }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = Model()
  var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenu()
    model.onLanguageChange = { [weak self] in
      self?.buildMenu()
      self?.model.objectWillChange.send()
    }

    let window = NSWindow(contentViewController: NSHostingController(rootView: ContentView(model: model)))
    window.title = "Git Tag Sync"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.center()
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
  }

  /// メニューバーを作る（言語を変えたときも作り直す）
  func buildMenu() {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: L("Quit Git Tag Sync"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: L("Window"))
    windowMenu.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    // 言語（ウインドウ右上の地球儀と同じ）
    let languageItem = NSMenuItem()
    mainMenu.addItem(languageItem)
    let languageMenu = NSMenu(title: L("Language"))
    for (title, code) in [(L("System Setting"), ""), ("English", "en"), ("日本語", "ja")] {
      let item = NSMenuItem(title: title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = code
      item.state = model.language == code ? .on : .off
      languageMenu.addItem(item)
    }
    languageItem.submenu = languageMenu
    NSApp.mainMenu = mainMenu
  }

  @objc func chooseLanguage(_ sender: NSMenuItem) {
    model.language = sender.representedObject as? String ?? ""
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    if !model.syncing && !model.busy { model.load() }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 起動

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--run": exit(runFromCommandLine(Array(arguments.dropFirst())))
case "--untag": exit(untagFromCommandLine(Array(arguments.dropFirst())))
case "--version":
  print("Git Tag Sync \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
  exit(0)
default: break
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
