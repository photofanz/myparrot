import SwiftUI
import MyParrotCore

/// App UI display language (separate from the speech-recognition language).
/// Default follows the system; unsupported system languages fall back to English.
/// User-overridable in Settings, switches live.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, en, zhTW, ja, ko, zhCN
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟隨系統 / System"
        case .en:     return "English"
        case .zhTW:   return "繁體中文"
        case .ja:     return "日本語"
        case .ko:     return "한국어"
        case .zhCN:   return "简体中文"
        }
    }
}

@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()
    var language: AppLanguage = .system {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "uiLanguage") }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "uiLanguage"),
           let l = AppLanguage(rawValue: raw) { language = l }
    }

    /// Resolve to a concrete language, following the OS when `.system`.
    private var resolved: AppLanguage {
        if language != .system { return language }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.language.region?.identifier
        switch code {
        case "zh": return (region == "CN" || region == "SG") ? .zhCN : .zhTW
        case "ja": return .ja
        case "ko": return .ko
        case "en": return .en
        default:   return .en
        }
    }

    /// BCP-47 identifier of the resolved UI language — for Foundation formatters
    /// (DateComponentsFormatter 等) that need a Locale, not a table lookup.
    var localeIdentifier: String {
        switch resolved {
        case .en: return "en"
        case .zhTW: return "zh-Hant"
        case .ja: return "ja"
        case .ko: return "ko"
        case .zhCN: return "zh-Hans"
        case .system: return "en"
        }
    }

    /// Keys are the 繁中 strings already in the views, so `.zhTW` returns the key.
    func t(_ key: String) -> String {
        let lang = resolved
        if lang == .zhTW { return key }
        return Self.table[key]?[lang] ?? Self.table[key]?[.en] ?? key
    }

    private static let table: [String: [AppLanguage: String]] = [
        // 二審 Finding 8(zh-lint-skip:承接既有翻譯表慣例,.ja/.zhCN 欄為刻意的
        // 日文/簡體原文)。原「迷你模式」key 的舊呼叫點(舊 miniMode 切換鈕)已被
        // 本輪 UI-25 三態 windowMode.cycle() 鈕取代,整個專案已無呼叫點——孤兒
        // key,清掉(不影響 check-translations,它只檢查「用了但缺翻譯」,不檢查
        // 反向;⚠️ 這裡故意不把那個 key 名字寫成 L 加引號的樣子,script 的掃描器
        // 不分辨註解與程式碼,寫成那樣會被誤判成新的使用點)。
        "設定": [.en: "Settings", .ja: "設定", .ko: "설정", .zhCN: "设置"],
        "完成": [.en: "Done", .ja: "完了", .ko: "완료", .zhCN: "完成"],
        "待錄音": [.en: "Ready", .ja: "待機中", .ko: "대기 중", .zhCN: "待录音"],
        "錄音中": [.en: "Recording", .ja: "録音中", .ko: "녹음 중", .zhCN: "录音中"],
        "已暫停": [.en: "Paused", .ja: "一時停止", .ko: "일시정지", .zhCN: "已暂停"],
        "結束後": [.en: "Finished", .ja: "終了", .ko: "완료", .zhCN: "结束后"],
        "對方": [.en: "Them", .ja: "相手", .ko: "상대방", .zhCN: "对方"],
        "你": [.en: "You", .ja: "あなた", .ko: "나", .zhCN: "你"],
        "會議名稱": [.en: "Meeting name", .ja: "会議名", .ko: "회의 이름", .zhCN: "会议名称"],
        // #2438 UI v2 遙控器(M3)
        "標記": [.en: "Mark", .ja: "マーク", .ko: "표시", .zhCN: "标记"],
        "模式": [.en: "Mode", .ja: "モード", .ko: "모드", .zhCN: "模式"],
        "增益": [.en: "Gain", .ja: "ゲイン", .ko: "게인", .zhCN: "增益"],
        "輸入增益": [.en: "Input gain", .ja: "入力ゲイン", .ko: "입력 게인", .zhCN: "输入增益"],
        "麥克風與輸入增益": [.en: "Microphone & input gain", .ja: "マイクと入力ゲイン", .ko: "마이크 및 입력 게인", .zhCN: "麦克风与输入增益"],
        "切換中…": [.en: "Switching…", .ja: "切り替え中…", .ko: "전환 중…", .zhCN: "切换中…"],   // AUD-38 麥克風藥丸
        "沒有可用的麥克風": [.en: "No microphone available", .ja: "使用できるマイクがありません", .ko: "사용 가능한 마이크가 없습니다", .zhCN: "没有可用的麦克风"],
        "呼…呼…": [.en: "Phew…", .ja: "はぁ…はぁ…", .ko: "헉…헉…", .zhCN: "呼…呼…"],
        "好耶": [.en: "Yay!", .ja: "やったー", .ko: "좋았어!", .zhCN: "好耶"],
        // #2438 M5 筆記面板
        "編輯": [.en: "Edit", .ja: "編集", .ko: "편집", .zhCN: "编辑"],
        "預覽": [.en: "Preview", .ja: "プレビュー", .ko: "미리보기", .zhCN: "预览"],
        "已存": [.en: "Saved", .ja: "保存済み", .ko: "저장됨", .zhCN: "已存"],
        "儲存中…": [.en: "Saving…", .ja: "保存中…", .ko: "저장 중…", .zhCN: "保存中…"],
        "尚未附到任何錄音": [.en: "Not attached to a recording yet", .ja: "まだ録音に紐付いていません", .ko: "아직 녹음에 연결되지 않음", .zhCN: "尚未附到任何录音"],
        "純 .md，1 秒自動存檔 · Enter 接清單 · ⌘⏎ 切勾選": [.en: "Plain .md, autosaves in 1 s · Enter continues lists · ⌘⏎ toggles checkbox", .ja: "プレーン .md、1 秒で自動保存 · Enter でリスト継続 · ⌘⏎ でチェック切替", .ko: "순수 .md, 1초 자동 저장 · Enter로 목록 이어쓰기 · ⌘⏎로 체크 전환", .zhCN: "纯 .md，1 秒自动保存 · Enter 接列表 · ⌘⏎ 切勾选"],
        "標題": [.en: "Heading", .ja: "見出し", .ko: "제목", .zhCN: "标题"],
        "粗體": [.en: "Bold", .ja: "太字", .ko: "굵게", .zhCN: "粗体"],
        "斜體": [.en: "Italic", .ja: "斜体", .ko: "기울임", .zhCN: "斜体"],
        "刪除線": [.en: "Strikethrough", .ja: "取り消し線", .ko: "취소선", .zhCN: "删除线"],
        "清單": [.en: "Bulleted list", .ja: "箇条書き", .ko: "글머리 기호 목록", .zhCN: "列表"],
        "編號清單": [.en: "Numbered list", .ja: "番号付きリスト", .ko: "번호 매기기 목록", .zhCN: "编号列表"],
        "勾選框": [.en: "Checkbox", .ja: "チェックボックス", .ko: "체크박스", .zhCN: "复选框"],
        "引用": [.en: "Quote", .ja: "引用", .ko: "인용", .zhCN: "引用"],
        "程式碼": [.en: "Code", .ja: "コード", .ko: "코드", .zhCN: "代码"],
        "連結": [.en: "Link", .ja: "リンク", .ko: "링크", .zhCN: "链接"],
        "表格": [.en: "Table", .ja: "表", .ko: "표", .zhCN: "表格"],
        "分隔線": [.en: "Divider", .ja: "区切り線", .ko: "구분선", .zhCN: "分隔线"],
        "欄 1": [.en: "Column 1", .ja: "列 1", .ko: "열 1", .zhCN: "栏 1"],
        "欄 2": [.en: "Column 2", .ja: "列 2", .ko: "열 2", .zhCN: "栏 2"],
        // #2438 M5 會議記錄面板
        "摘要": [.en: "Summary", .ja: "要約", .ko: "요약", .zhCN: "摘要"],
        "決議": [.en: "Decisions", .ja: "決定事項", .ko: "결정 사항", .zhCN: "决议"],
        "待辦": [.en: "Action items", .ja: "アクション", .ko: "할 일", .zhCN: "待办"],
        "待釐清": [.en: "Open questions", .ja: "未解決の質問", .ko: "미해결 질문", .zhCN: "待厘清"],
        "時間軸": [.en: "Timeline", .ja: "タイムライン", .ko: "타임라인", .zhCN: "时间轴"],
        "立即更新": [.en: "Update now", .ja: "今すぐ更新", .ko: "지금 업데이트", .zhCN: "立即更新"],
        "產生會議記錄": [.en: "Generate minutes", .ja: "議事録を作成", .ko: "회의록 생성", .zhCN: "生成会议记录"],
        "複製 Markdown": [.en: "Copy Markdown", .ja: "Markdown をコピー", .ko: "Markdown 복사", .zhCN: "复制 Markdown"],
        "貼到筆記": [.en: "Paste into notes", .ja: "メモに貼り付け", .ko: "메모에 붙여넣기", .zhCN: "贴到笔记"],
        "在編輯器打開": [.en: "Open in editor", .ja: "エディタで開く", .ko: "편집기에서 열기", .zhCN: "在编辑器打开"],
        "更新於": [.en: "Updated", .ja: "更新", .ko: "업데이트", .zhCN: "更新于"],
        "每 %@ 分": [.en: "every %@ min", .ja: "%@ 分ごと", .ko: "%@분마다", .zhCN: "每 %@ 分"],
        "手動": [.en: "Manual", .ja: "手動", .ko: "수동", .zhCN: "手动"],
        "尚未設定會議記錄的模型後端": [.en: "No model backend set for minutes", .ja: "議事録のモデルバックエンドが未設定です", .ko: "회의록용 모델 백엔드가 설정되지 않음", .zhCN: "尚未设置会议记录的模型后端"],
        "開始錄音後每 %@ 分鐘自動整理一次（可在設定調整或關閉；也可隨時按「立即更新」）": [.en: "After recording starts, minutes are compiled every %@ minutes (adjust or turn off in Settings; or press “Update now” any time)", .ja: "録音開始後、%@ 分ごとに自動で整理します（設定で調整・停止可。「今すぐ更新」も使えます）", .ko: "녹음 시작 후 %@분마다 자동 정리합니다(설정에서 조정·해제 가능, “지금 업데이트”도 가능)", .zhCN: "开始录音后每 %@ 分钟自动整理一次（可在设置调整或关闭；也可随时按“立即更新”）"],
        "會議記錄尚未產生": [.en: "Minutes not generated yet", .ja: "議事録はまだ作成されていません", .ko: "회의록이 아직 생성되지 않음", .zhCN: "会议记录尚未生成"],
        // #2438 M5 檔案面板(改名／垃圾桶)
        "重新命名": [.en: "Rename", .ja: "名前を変更", .ko: "이름 변경", .zhCN: "重新命名"],
        "同一場的錄音、逐字稿、筆記、會議記錄會一起改名；日期時間前綴不變。": [.en: "The recording, transcript, notes and minutes of this session are renamed together; the date-time prefix stays.", .ja: "この回の録音・文字起こし・メモ・議事録をまとめて改名します。日時の接頭辞は変わりません。", .ko: "이 회차의 녹음·전사·메모·회의록이 함께 이름이 바뀝니다. 날짜·시간 접두사는 그대로입니다.", .zhCN: "同一场的录音、逐字稿、笔记、会议记录会一起改名；日期时间前缀不变。"],
        "取消": [.en: "Cancel", .ja: "キャンセル", .ko: "취소", .zhCN: "取消"],
        "無法重新命名": [.en: "Can’t rename", .ja: "名前を変更できません", .ko: "이름을 변경할 수 없음", .zhCN: "无法重新命名"],
        "移到垃圾桶": [.en: "Move to Trash", .ja: "ゴミ箱に入れる", .ko: "휴지통으로 이동", .zhCN: "移到废纸篓"],
        "這些檔案會移到垃圾桶（可從垃圾桶救回）：": [.en: "These files will be moved to the Trash (recoverable from the Trash):", .ja: "次のファイルをゴミ箱に入れます（ゴミ箱から戻せます）:", .ko: "다음 파일을 휴지통으로 이동합니다(휴지통에서 복구 가능):", .zhCN: "这些文件会移到废纸篓（可从废纸篓救回）："],
        "無法移到垃圾桶": [.en: "Can’t move to Trash", .ja: "ゴミ箱に入れられません", .ko: "휴지통으로 이동할 수 없음", .zhCN: "无法移到废纸篓"],
        "名稱清理後是空的，請換一個名稱。": [.en: "The name is empty after cleanup. Please choose another.", .ja: "整理後の名前が空です。別の名前にしてください。", .ko: "정리 후 이름이 비어 있습니다. 다른 이름을 선택하세요.", .zhCN: "名称清理后是空的，请换一个名称。"],
        "名稱沒有變。": [.en: "The name didn’t change.", .ja: "名前は変わっていません。", .ko: "이름이 바뀌지 않았습니다.", .zhCN: "名称没有变。"],
        "已有同名檔案：": [.en: "A file with that name already exists: ", .ja: "同名のファイルがあります: ", .ko: "같은 이름의 파일이 이미 있습니다: ", .zhCN: "已有同名文件："],
        "找不到這場的檔案，可能已被移走。": [.en: "This session’s files can’t be found; they may have been moved.", .ja: "この回のファイルが見つかりません。移動された可能性があります。", .ko: "이 회차의 파일을 찾을 수 없습니다. 이동되었을 수 있습니다.", .zhCN: "找不到这场的文件，可能已被移走。"],
        "這場正在錄音、轉檔或轉逐字稿，等它完成再試。": [.en: "This session is recording, converting or transcribing. Try again when it finishes.", .ja: "この回は録音・変換・文字起こし中です。完了後にやり直してください。", .ko: "이 회차는 녹음·변환·전사 중입니다. 완료 후 다시 시도하세요.", .zhCN: "这场正在录音、转档或转逐字稿，等它完成再试。"],
        "記錄": [.en: "Minutes", .ja: "議事録", .ko: "회의록", .zhCN: "记录"],
        "引用到筆記": [.en: "Quote into notes", .ja: "メモに引用", .ko: "메모에 인용", .zhCN: "引用到笔记"],
        "跟到最新": [.en: "Follow latest", .ja: "最新に追従", .ko: "최신 따라가기", .zhCN: "跟到最新"],
        "搜尋標題": [.en: "Search titles", .ja: "タイトルを検索", .ko: "제목 검색", .zhCN: "搜索标题"],
        "沒有符合的錄音": [.en: "No matching recordings", .ja: "該当する録音はありません", .ko: "일치하는 녹음 없음", .zhCN: "没有符合的录音"],
        "打開筆記": [.en: "Open notes", .ja: "メモを開く", .ko: "메모 열기", .zhCN: "打开笔记"],
        "打開會議記錄": [.en: "Open minutes", .ja: "議事録を開く", .ko: "회의록 열기", .zhCN: "打开会议记录"],
        "重新命名…": [.en: "Rename…", .ja: "名前を変更…", .ko: "이름 변경…", .zhCN: "重新命名…"],
        "移到垃圾桶…": [.en: "Move to Trash…", .ja: "ゴミ箱に入れる…", .ko: "휴지통으로 이동…", .zhCN: "移到废纸篓…"],
        "草稿": [.en: "Draft", .ja: "下書き", .ko: "초안", .zhCN: "草稿"],
        // #2438 UI v2 面板工作區(M4)
        "筆記": [.en: "Notes", .ja: "メモ", .ko: "노트", .zhCN: "笔记"],
        "會議記錄": [.en: "Minutes", .ja: "議事録", .ko: "회의록", .zhCN: "会议记录"],
        "控制欄靠左": [.en: "Controls on Left", .ja: "コントロールを左に", .ko: "컨트롤을 왼쪽에", .zhCN: "控制栏靠左"],
        "控制欄靠右": [.en: "Controls on Right", .ja: "コントロールを右に", .ko: "컨트롤을 오른쪽에", .zhCN: "控制栏靠右"],
        "往左移": [.en: "Move Left", .ja: "左へ移動", .ko: "왼쪽으로 이동", .zhCN: "往左移"],
        "往右移": [.en: "Move Right", .ja: "右へ移動", .ko: "오른쪽으로 이동", .zhCN: "往右移"],
        "關閉面板": [.en: "Close Panel", .ja: "パネルを閉じる", .ko: "패널 닫기", .zhCN: "关闭面板"],
        "拖曳換位": [.en: "Drag to reorder", .ja: "ドラッグで並べ替え", .ko: "드래그하여 순서 변경", .zhCN: "拖拽换位"],
        "拖曳控制欄換邊": [.en: "Drag to move the controls to the other side", .ja: "ドラッグでコントロールを反対側へ", .ko: "드래그하여 컨트롤을 반대쪽으로", .zhCN: "拖拽控制栏换边"],
        "調整欄寬": [.en: "Resize column", .ja: "列幅を調整", .ko: "열 너비 조정", .zhCN: "调整栏宽"],
        "會議筆記會顯示在這裡": [.en: "Meeting notes will appear here", .ja: "会議メモはここに表示されます", .ko: "회의 노트가 여기에 표시됩니다", .zhCN: "会议笔记会显示在这里"],
        "會議記錄草稿會顯示在這裡": [.en: "Draft minutes will appear here", .ja: "議事録の下書きはここに表示されます", .ko: "회의록 초안이 여기에 표시됩니다", .zhCN: "会议记录草稿会显示在这里"],
        "開始錄音": [.en: "Record", .ja: "録音開始", .ko: "녹음 시작", .zhCN: "开始录音"],
        "暫停": [.en: "Pause", .ja: "一時停止", .ko: "일시정지", .zhCN: "暂停"],
        // UI-27/28 播放(2026-08-23)
        "播放": [.en: "Play", .ja: "再生", .ko: "재생", .zhCN: "播放"],
        "重播": [.en: "Replay", .ja: "もう一度再生", .ko: "다시 재생", .zhCN: "重播"],
        "從頭播放": [.en: "Play from Start", .ja: "最初から再生", .ko: "처음부터 재생", .zhCN: "从头播放"],
        "停止播放": [.en: "Stop Playback", .ja: "再生を停止", .ko: "재생 중지", .zhCN: "停止播放"],
        "播放進度": [.en: "Playback position", .ja: "再生位置", .ko: "재생 위치", .zhCN: "播放进度"],
        "波形不可用": [.en: "No waveform", .ja: "波形なし", .ko: "파형 없음", .zhCN: "波形不可用"],
        "打開逐字稿": [.en: "Open Transcript", .ja: "文字起こしを開く", .ko: "받아쓰기 열기", .zhCN: "打开逐字稿"],
        "轉檔中,完成後自動轉逐字稿…": [.en: "Converting — will transcribe when done…", .ja: "変換中 — 完了後に文字起こしします…", .ko: "변환 중 — 완료 후 받아쓰기합니다…", .zhCN: "转档中,完成后自动转写…"],
        "重新轉逐字稿": [.en: "Re-transcribe", .ja: "再文字起こし", .ko: "다시 받아쓰기", .zhCN: "重新转写"],
        // VoiceOver 進度值模板(三鏡頭審:連接詞拆開翻成 en "of" 塞進固定模板會破句)。
        "已播 %@,共 %@": [.en: "%@ played of %@", .ja: "%@ 再生済み、全体 %@", .ko: "%@ 재생됨, 전체 %@", .zhCN: "已播 %@,共 %@"],
        "繼續": [.en: "Resume", .ja: "再開", .ko: "계속", .zhCN: "继续"],
        "結束": [.en: "Stop", .ja: "終了", .ko: "종료", .zhCN: "结束"],
        "新錄音": [.en: "New", .ja: "新規録音", .ko: "새 녹음", .zhCN: "新录音"],
        "最近錄音": [.en: "Recent", .ja: "最近の録音", .ko: "최근 녹음", .zhCN: "最近录音"],
        "在 Finder 打開": [.en: "Show in Finder", .ja: "Finderで表示", .ko: "Finder에서 열기", .zhCN: "在访达中打开"],
        "尚無錄音": [.en: "No recordings yet", .ja: "録音はまだありません", .ko: "녹음 없음", .zhCN: "尚无录音"],
        "雙聲道": [.en: "Stereo", .ja: "ステレオ", .ko: "스테레오", .zhCN: "双声道"],
        "雙聲道 · 已轉稿": [.en: "Stereo · Transcribed", .ja: "ステレオ・文字起こし済み", .ko: "스테레오 · 변환됨", .zhCN: "双声道 · 已转写"],
        "處理中…": [.en: "Processing…", .ja: "処理中…", .ko: "처리 중…", .zhCN: "处理中…"],
        "收音中": [.en: "Live", .ja: "受信中", .ko: "수신 중", .zhCN: "收音中"],
        "錄音中收音": [.en: "Capturing (recording)", .ja: "録音中・受信中", .ko: "녹음 중 수신", .zhCN: "录音中收音"],
        "等待訊號": [.en: "No signal", .ja: "信号なし", .ko: "신호 없음", .zhCN: "等待信号"],
        "轉逐字稿": [.en: "Transcribe", .ja: "文字起こし", .ko: "받아쓰기", .zhCN: "转写"],
        "3 分鐘": [.en: "3 min", .ja: "3分", .ko: "3분", .zhCN: "3 分钟"],
        "完整": [.en: "Full", .ja: "全文", .ko: "전체", .zhCN: "完整"],
        "轉逐字稿中…": [.en: "Transcribing…", .ja: "文字起こし中…", .ko: "변환 중…", .zhCN: "转写中…"],
        // UI-33 列上排隊狀態(zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文,比照既有翻譯表慣例)
        "已排隊,稍後轉逐字稿…": [.en: "Queued — will transcribe shortly…", .ja: "待機中 — まもなく文字起こし…", .ko: "대기 중 — 곧 변환합니다…", .zhCN: "已排队,稍后转写…"],
        // UI-33b footer build no 連 GitHub(zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文)
        "在 GitHub 上打開 MyParrot": [.en: "Open MyParrot on GitHub", .ja: "GitHub で MyParrot を開く", .ko: "GitHub에서 MyParrot 열기", .zhCN: "在 GitHub 上打开 MyParrot"],
        "開始錄音後,逐字稿會即時顯示在這裡;或對任一錄音檔按「轉逐字稿」。": [
            .en: "Transcript appears here while recording — or press Transcribe on any recording.",
            .ja: "録音中はここに文字起こしが表示されます。録音を選んで「文字起こし」も可能。",
            .ko: "녹음 중 여기에 받아쓰기가 표시됩니다. 녹음에서 '받아쓰기'를 눌러도 됩니다.",
            .zhCN: "开始录音后,字幕会实时显示在这里;或对任一录音按「转写」。"],
        "分軌讓「誰說的」自動標好(對方左／你右)": [
            .en: "Split channels auto-label the speaker (Them = L / You = R)",
            .ja: "チャンネル分離で話者を自動判別(相手=左／あなた=右)",
            .ko: "채널 분리로 화자 자동 구분 (상대방=왼쪽 / 나=오른쪽)",
            .zhCN: "分轨让「谁说的」自动标好(对方左／你右)"],
        "廣告": [.en: "Ad", .ja: "広告", .ko: "광고", .zhCN: "广告"],
        "免費版顯示一行小廣告": [.en: "Free version shows a small ad", .ja: "無料版では小さな広告が表示されます", .ko: "무료 버전은 작은 광고를 표시합니다", .zhCN: "免费版显示一行小广告"],
        "升級移除": [.en: "Remove", .ja: "削除", .ko: "제거", .zhCN: "升级移除"],
        "需要麥克風 / 語音辨識 / 系統音訊權限": [
            .en: "Needs Microphone / Speech / System Audio permission",
            .ja: "マイク／音声認識／システム音声の権限が必要",
            .ko: "마이크 / 음성 인식 / 시스템 오디오 권한 필요",
            .zhCN: "需要麦克风 / 语音识别 / 系统音频权限"],
        "授權": [.en: "Grant", .ja: "許可", .ko: "허용", .zhCN: "授权"],
        // Settings
        "輸入來源(分兩軌)": [.en: "Input (two channels)", .ja: "入力ソース(2チャンネル)", .ko: "입력 소스(2채널)", .zhCN: "输入来源(分两轨)"],
        "對方聲音(左軌)": [.en: "Their voice (Left)", .ja: "相手の声(左)", .ko: "상대방 음성(왼쪽)", .zhCN: "对方声音(左轨)"],
        "系統音訊 · 全部": [.en: "System audio · All", .ja: "システム音声・全体", .ko: "시스템 오디오 · 전체", .zhCN: "系统音频 · 全部"],
        "你的麥克風(右軌)": [.en: "Your mic (Right)", .ja: "あなたのマイク(右)", .ko: "내 마이크(오른쪽)", .zhCN: "你的麦克风(右轨)"],
        "(藍牙)": [.en: " (Bluetooth)", .ja: "(Bluetooth)", .ko: " (블루투스)", .zhCN: "(蓝牙)"],
        "(iPhone)": [.en: " (iPhone)", .ja: "(iPhone)", .ko: " (iPhone)", .zhCN: "(iPhone)"],
        "聆聽輸出": [.en: "Listening output", .ja: "再生出力", .ko: "듣기 출력", .zhCN: "聆听输出"],
        "跟隨系統 · 不影響錄音": [.en: "Follow system · Doesn't affect recording", .ja: "システムに従う・録音に影響なし", .ko: "시스템 따름 · 녹음에 영향 없음", .zhCN: "跟随系统 · 不影响录音"],
        "提醒:麥克風別選藍牙耳機,否則整條藍牙掉 HFP,對方聲音也會變糊。": [
            .en: "Tip: don't use a Bluetooth mic — it drops the link to HFP and muddies their voice too.",
            .ja: "ヒント:マイクにBluetoothを使わないで。HFPに切替わり相手の声も劣化します。",
            .ko: "팁: 마이크로 블루투스를 쓰지 마세요. HFP로 전환되어 상대방 음성도 흐려집니다.",
            .zhCN: "提醒:麦克风别选蓝牙耳机,否则整条蓝牙掉 HFP,对方声音也会变糊。"],
        "錄音": [.en: "Recording", .ja: "録音", .ko: "녹음", .zhCN: "录音"],
        "麥克風靈敏度": [.en: "Mic sensitivity", .ja: "マイク感度", .ko: "마이크 감도", .zhCN: "麦克风灵敏度"],
        "對著麥克風講話測試": [.en: "Speak to test", .ja: "話してテスト", .ko: "말해서 테스트", .zhCN: "对着麦克风讲话测试"],
        "錄音時即時逐字稿": [.en: "Live transcript while recording", .ja: "録音中にリアルタイム文字起こし", .ko: "녹음 중 실시간 받아쓰기", .zhCN: "录音时实时字幕"],
        "回音消除(喇叭外放·停止後處理)": [.en: "Echo cleanup (speakers · after stop)", .ja: "エコー除去(スピーカー・停止後)", .ko: "에코 제거(스피커 · 정지 후)", .zhCN: "回音消除(扬声器外放·停止后处理)"],
        "用喇叭(非耳機)開會時,停止後自動消掉對方聲音被麥克風收進去的回音;純後製、不影響開會當下的聲音。": [
            .en: "When meeting on speakers (not headphones), removes the other party's voice that bled into your mic, after you stop. Post-processing only — doesn't affect live meeting audio.",
            .ja: "スピーカー(イヤホン以外)で会議する際、停止後に相手の声がマイクに入った反響を除去。後処理のみで会議中の音には影響しません。",
            .ko: "스피커(이어폰 아님)로 회의할 때 정지 후 상대방 소리가 마이크에 들어간 반향을 제거; 후처리만 하며 회의 중 소리에는 영향 없음.",
            .zhCN: "用扬声器(非耳机)开会时,停止后自动消掉对方声音被麦克风收进去的回音;纯后期、不影响开会当下的声音。"],
        "錄音格式": [.en: "Recording format", .ja: "録音フォーマット", .ko: "녹음 형식", .zhCN: "录音格式"],
        "錄製 PCM → 存檔 m4a(雙聲道)": [.en: "Capture PCM → Save m4a (stereo)", .ja: "録音PCM → 保存m4a(ステレオ)", .ko: "녹음 PCM → 저장 m4a(스테레오)", .zhCN: "录制 PCM → 存档 m4a(双声道)"],
        "逐字稿": [.en: "Transcript", .ja: "文字起こし", .ko: "받아쓰기", .zhCN: "字幕"],
        "辨識語言": [.en: "Recognition language", .ja: "認識言語", .ko: "인식 언어", .zhCN: "识别语言"],
        "介面語言": [.en: "Display language", .ja: "表示言語", .ko: "표시 언어", .zhCN: "界面语言"],
        // UI-56 外觀(Eric 2026-10-20)
        "外觀": [.en: "Appearance", .ja: "外観", .ko: "모양", .zhCN: "外观"],
        // #2483 E 結束後高精度重轉時機(TRX-05/07)
        "結束後高精度重轉": [.en: "High-accuracy re-transcription after stop", .ja: "停止後の高精度再文字起こし", .ko: "정지 후 고정밀 재전사", .zhCN: "结束后高精度重转"],
        "立刻": [.en: "Immediately", .ja: "すぐに", .ko: "즉시", .zhCN: "立刻"],
        "閒置時(接電、沒在錄音)": [.en: "When idle (on power, not recording)", .ja: "アイドル時(電源接続中・録音していない時)", .ko: "유휴 시(전원 연결, 녹음 중 아님)", .zhCN: "闲置时(接电、没在录音)"],
        "不重轉": [.en: "Never", .ja: "しない", .ko: "안 함", .zhCN: "不重转"],
        "待高精度重轉": [.en: "awaiting high-accuracy pass", .ja: "高精度再処理待ち", .ko: "고정밀 재전사 대기", .zhCN: "待高精度重转"],
        "現在重轉": [.en: "Re-transcribe now", .ja: "今すぐ再文字起こし", .ko: "지금 재전사", .zhCN: "现在重转"],
        // #2438 Phase 3a Apple Foundation Models(AFM-01/02/11)
        "Apple 本機模型": [.en: "Apple on-device model", .ja: "Apple オンデバイスモデル", .ko: "Apple 온디바이스 모델", .zhCN: "Apple 本机模型"],
        "Apple 本機模型可用": [.en: "Apple on-device model is available", .ja: "Apple オンデバイスモデルを利用できます", .ko: "Apple 온디바이스 모델을 사용할 수 있습니다", .zhCN: "Apple 本机模型可用"],
        "Apple 本機模型:資料不出機": [.en: "Apple on-device model: nothing leaves this Mac", .ja: "Apple オンデバイスモデル:データはこの Mac から出ません", .ko: "Apple 온디바이스 모델: 데이터가 이 Mac을 벗어나지 않습니다", .zhCN: "Apple 本机模型:数据不出机"],
        "Apple 本機模型需要 macOS 26 以上": [.en: "Apple on-device model requires macOS 26 or later", .ja: "Apple オンデバイスモデルには macOS 26 以降が必要です", .ko: "Apple 온디바이스 모델은 macOS 26 이상이 필요합니다", .zhCN: "Apple 本机模型需要 macOS 26 以上"],
        "這台 Mac 不支援 Apple Intelligence": [.en: "This Mac doesn't support Apple Intelligence", .ja: "この Mac は Apple Intelligence に対応していません", .ko: "이 Mac은 Apple Intelligence를 지원하지 않습니다", .zhCN: "这台 Mac 不支持 Apple Intelligence"],
        "Apple Intelligence 尚未開啟:系統設定 → Apple Intelligence 與 Siri": [.en: "Apple Intelligence is off: System Settings → Apple Intelligence & Siri", .ja: "Apple Intelligence がオフです:システム設定 → Apple Intelligence と Siri", .ko: "Apple Intelligence가 꺼져 있습니다: 시스템 설정 → Apple Intelligence 및 Siri", .zhCN: "Apple Intelligence 尚未开启:系统设置 → Apple Intelligence 与 Siri"],
        "Apple 模型尚未就緒:請確認 Siri 語言與系統語言相同、Apple Intelligence 已開啟;模型可能還在下載": [.en: "Apple model not ready: make sure the Siri language matches the system language and Apple Intelligence is on; the model may still be downloading", .ja: "Apple モデルの準備ができていません:Siri の言語がシステム言語と同じで、Apple Intelligence がオンか確認してください。モデルをダウンロード中の可能性もあります", .ko: "Apple 모델이 준비되지 않았습니다: Siri 언어가 시스템 언어와 같고 Apple Intelligence가 켜져 있는지 확인하세요. 모델을 아직 다운로드 중일 수 있습니다", .zhCN: "Apple 模型尚未就绪:请确认 Siri 语言与系统语言相同、Apple Intelligence 已开启;模型可能还在下载"],
        "Apple 本機模型目前無法使用": [.en: "Apple on-device model is currently unavailable", .ja: "Apple オンデバイスモデルは現在利用できません", .ko: "Apple 온디바이스 모델을 현재 사용할 수 없습니다", .zhCN: "Apple 本机模型目前无法使用"],
        // UI-57 首次啟動模型功能提示(Eric 2026-10-20 A1)
        "逐字稿校正與會議記錄要先在設定開啟": [.en: "Transcript correction and meeting minutes are off until you turn them on in Settings", .ja: "文字起こしの校正と議事録は、設定でオンにするまで使えません", .ko: "전사 교정과 회의록은 설정에서 켜야 사용할 수 있습니다", .zhCN: "逐字稿校正与会议记录要先在设置开启"],
        "這兩個功能預設關閉,沒選模型後端時不會出現。到「設定 → 模型」各自選後端:Apple 本機模型資料不出機;Claude CLI／Codex CLI 用你自己的訂閱。隨時可以再關掉。": [.en: "Both are off by default and stay hidden until a model backend is chosen. Go to Settings → Model and pick a backend for each: the Apple on-device model keeps everything on this Mac; Claude CLI and Codex CLI use your own subscriptions. You can turn them off again anytime.", .ja: "どちらも初期状態ではオフで、モデルのバックエンドを選ぶまで表示されません。「設定 → モデル」でそれぞれバックエンドを選んでください。Apple オンデバイスモデルはデータがこの Mac から出ず、Claude CLI と Codex CLI はあなた自身のサブスクリプションを使います。いつでもオフに戻せます。", .ko: "두 기능은 기본적으로 꺼져 있고 모델 백엔드를 선택하기 전까지 표시되지 않습니다. 설정 → 모델에서 각각 백엔드를 고르세요. Apple 온디바이스 모델은 데이터가 이 Mac을 벗어나지 않고, Claude CLI와 Codex CLI는 본인 구독을 사용합니다. 언제든 다시 끌 수 있습니다.", .zhCN: "这两个功能默认关闭,没选模型后端时不会出现。到「设置 → 模型」各自选后端:Apple 本机模型数据不出机;Claude CLI／Codex CLI 用你自己的订阅。随时可以再关掉。"],
        "打開設定": [.en: "Open Settings", .ja: "設定を開く", .ko: "설정 열기", .zhCN: "打开设置"],
        "稍後": [.en: "Later", .ja: "あとで", .ko: "나중에", .zhCN: "稍后"],
        "淺色": [.en: "Light", .ja: "ライト", .ko: "라이트", .zhCN: "浅色"],
        "深色": [.en: "Dark", .ja: "ダーク", .ko: "다크", .zhCN: "深色"],
        "預設跟隨系統語言;不支援的語言會用英文。支援:英/繁中/日/韓/簡中。": [
            .en: "Defaults to the system language; unsupported ones use English. Supported: EN / 繁中 / JA / KO / 简中.",
            .ja: "既定はシステム言語。非対応は英語。対応:英/繁中/日/韓/簡中。",
            .ko: "기본은 시스템 언어. 미지원은 영어. 지원: 영/번체/일/한/간체.",
            .zhCN: "默认跟随系统语言;不支持的语言用英文。支持:英/繁中/日/韩/简中。"],
        "引擎": [.en: "Engine", .ja: "エンジン", .ko: "엔진", .zhCN: "引擎"],
        "存檔": [.en: "Storage", .ja: "保存先", .ko: "저장", .zhCN: "存档"],
        "存檔目錄": [.en: "Save folder", .ja: "保存フォルダ", .ko: "저장 폴더", .zhCN: "存档目录"],
        "選擇…": [.en: "Choose…", .ja: "選択…", .ko: "선택…", .zhCN: "选择…"],
        "可指向 Google Drive 同步資料夾。": [.en: "Can point to a Google Drive synced folder.", .ja: "Google Drive同期フォルダを指定できます。", .ko: "Google Drive 동기화 폴더를 지정할 수 있습니다.", .zhCN: "可指向 Google Drive 同步文件夹。"],
        "檔名範本": [.en: "Filename", .ja: "ファイル名", .ko: "파일 이름", .zhCN: "文件名"],
        "日期+時間+會議名稱": [.en: "Date + Time + Meeting name", .ja: "日付+時刻+会議名", .ko: "날짜+시간+회의 이름", .zhCN: "日期+时间+会议名称"],
        "權限": [.en: "Permissions", .ja: "権限", .ko: "권한", .zhCN: "权限"],
        "麥克風": [.en: "Microphone", .ja: "マイク", .ko: "마이크", .zhCN: "麦克风"],
        "語音辨識": [.en: "Speech recognition", .ja: "音声認識", .ko: "음성 인식", .zhCN: "语音识别"],
        "已授權": [.en: "Granted", .ja: "許可済み", .ko: "허용됨", .zhCN: "已授权"],
        "未授權": [.en: "Not granted", .ja: "未許可", .ko: "미허용", .zhCN: "未授权"],
        "重新請求權限": [.en: "Request again", .ja: "再リクエスト", .ko: "다시 요청", .zhCN: "重新请求权限"],
        // Quit guard (recording in progress)
        "錄音還在進行中": [.en: "A recording is still in progress", .ja: "録音がまだ進行中です", .ko: "녹음이 아직 진행 중입니다", .zhCN: "录音还在进行中"],
        "要先結束並儲存這段錄音,還是繼續錄音?": [
            .en: "Stop and save this recording first, or keep recording?",
            .ja: "この録音を終了して保存しますか?それとも録音を続けますか?",
            .ko: "이 녹음을 끝내고 저장할까요, 아니면 계속 녹음할까요?",
            .zhCN: "要先结束并保存这段录音,还是继续录音?"],
        "繼續錄音": [.en: "Keep Recording", .ja: "録音を続ける", .ko: "계속 녹음", .zhCN: "继续录音"],
        "結束錄音並離開": [.en: "Stop & Quit", .ja: "終了して保存・終了", .ko: "끝내고 종료", .zhCN: "结束录音并退出"],
        // 逐字稿引擎(TR-14/16/19)
        "Whisper 模型": [.en: "Whisper model", .ja: "Whisper モデル", .ko: "Whisper 모델", .zhCN: "Whisper 模型"],
        "下載": [.en: "Download", .ja: "ダウンロード", .ko: "다운로드", .zhCN: "下载"],
        "刪除": [.en: "Delete", .ja: "削除", .ko: "삭제", .zhCN: "删除"],
        "使用": [.en: "Use", .ja: "使用", .ko: "사용", .zhCN: "使用"],
        "使用中": [.en: "In use", .ja: "使用中", .ko: "사용 중", .zhCN: "使用中"],
        "下載失敗": [.en: "Download failed", .ja: "ダウンロード失敗", .ko: "다운로드 실패", .zhCN: "下载失败"],
        "結束後自動產出高精度逐字稿": [
            .en: "Auto high-accuracy transcript after stop",
            .ja: "停止後に高精度文字起こしを自動生成",
            .ko: "정지 후 고정밀 전사 자동 생성",
            .zhCN: "结束后自动产出高精度逐字稿"],
        "錄音停止後用 Whisper 高精度重轉一次;即時稿僅供會中參考。": [
            .en: "Re-transcribes with Whisper after the recording stops; the live transcript is a meeting-time reference.",
            .ja: "録音停止後に Whisper で高精度に再文字起こしします。ライブ字幕は会議中の参考用です。",
            .ko: "녹음 정지 후 Whisper로 고정밀 재전사합니다. 실시간 자막은 참고용입니다.",
            .zhCN: "录音停止后用 Whisper 高精度重转一次;实时稿仅供会中参考。"],
        // UPD 自動更新檢查(zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文,比照既有翻譯表慣例)
        "軟體更新": [.en: "Software Update", .ja: "ソフトウェアアップデート", .ko: "소프트웨어 업데이트", .zhCN: "软件更新"],
        "啟動時自動檢查更新": [.en: "Check for updates at launch", .ja: "起動時にアップデートを確認", .ko: "실행 시 업데이트 확인", .zhCN: "启动时自动检查更新"],
        "立即檢查": [.en: "Check Now", .ja: "今すぐ確認", .ko: "지금 확인", .zhCN: "立即检查"],
        "檢查中…": [.en: "Checking…", .ja: "確認中…", .ko: "확인 중…", .zhCN: "检查中…"],
        "已是最新版本": [.en: "Up to date", .ja: "最新バージョンです", .ko: "최신 버전입니다", .zhCN: "已是最新版本"],
        "檢查失敗": [.en: "Check failed", .ja: "確認に失敗しました", .ko: "확인 실패", .zhCN: "检查失败"],
        "有新版本": [.en: "New version available:", .ja: "新しいバージョン:", .ko: "새 버전:", .zhCN: "有新版本"],
        "前往下載": [.en: "Download", .ja: "ダウンロード", .ko: "다운로드", .zhCN: "前往下载"],
        "略過此版": [.en: "Skip This Version", .ja: "このバージョンをスキップ", .ko: "이 버전 건너뛰기", .zhCN: "跳过此版本"],
        "目前版本": [.en: "Current version", .ja: "現在のバージョン", .ko: "현재 버전", .zhCN: "当前版本"],
        "檢查更新…": [.en: "Check for Updates…", .ja: "アップデートを確認…", .ko: "업데이트 확인…", .zhCN: "检查更新…"],
        // UI-24/25:快捷鍵選單(App menu「設定…」/「錄音」/「顯示方式」)+三態模式命名
        // (zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文,比照既有翻譯表慣例)。
        "設定…": [.en: "Settings…", .ja: "設定…", .ko: "설정…", .zhCN: "设置…"],
        // 二審 Finding 3 修正後「暫停」/「繼續」改用既有 key 動態組字(見
        // AppCommands),這顆固定字串「暫停／繼續」不再有呼叫點,一併清掉
        // (zh-lint-skip:上下相鄰行的 .ja/.zhCN 欄為既有翻譯表刻意的日文/簡體
        // 原文,非本次改動)。
        "結束錄音": [.en: "Stop Recording", .ja: "録音終了", .ko: "녹음 종료", .zhCN: "结束录音"],
        "顯示方式": [.en: "View", .ja: "表示", .ko: "보기", .zhCN: "显示方式"],
        "切換模式": [.en: "Switch Mode", .ja: "モード切替", .ko: "모드 전환", .zhCN: "切换模式"],
        "逐字稿 3 分鐘／完整": [.en: "Transcript: 3 min / Full", .ja: "文字起こし:3分／全文", .ko: "받아쓰기: 3분/전체", .zhCN: "字幕:3 分钟／完整"],
        "收折最近錄音": [.en: "Collapse Recent Recordings", .ja: "最近の録音を折りたたむ", .ko: "최근 녹음 접기", .zhCN: "折叠最近录音"],
        "展開最近錄音": [.en: "Expand Recent Recordings", .ja: "最近の録音を展開", .ko: "최근 녹음 펼치기", .zhCN: "展开最近录音"],
        "標準視窗": [.en: "Standard Window", .ja: "標準ウィンドウ", .ko: "표준 창", .zhCN: "标准窗口"],
        "窄版視窗": [.en: "Compact Window", .ja: "コンパクトウィンドウ", .ko: "축소 창", .zhCN: "窄版窗口"],
        // BUG-28(#1680)錄音中警示橫幅 + 設定頁 Core 標籤(zh-lint-skip:.ja/.zhCN 欄
        // 為刻意的日文/簡體譯文,比照既有翻譯表慣例)。key=Core 的繁中模板,
        // 見 MyParrotCore/RecordingWarning.swift 的 l10n-keys 標記區段。
        "逐字稿引擎將於本次錄音結束後生效": [
            .en: "The transcription engine change takes effect after this recording ends",
            .ja: "文字起こしエンジンの変更は今回の録音終了後に反映されます",
            .ko: "받아쓰기 엔진 변경은 이번 녹음이 끝난 뒤 적용됩니다",
            .zhCN: "转写引擎将于本次录音结束后生效"],
        "Whisper 模型未安裝 — 到設定下載後生效,暫用 macOS 原生引擎": [
            .en: "Whisper model not installed — download it in Settings; using the macOS engine for now",
            .ja: "Whisper モデルが未インストール — 設定でダウンロードすると有効になります。今は macOS 標準エンジンを使用中",
            .ko: "Whisper 모델이 설치되지 않았습니다 — 설정에서 내려받으면 적용됩니다. 지금은 macOS 기본 엔진 사용",
            .zhCN: "Whisper 模型未安装 — 到设置下载后生效,暂用 macOS 原生引擎"],
        "雲端引擎尚未設定,暫用 macOS 原生引擎": [
            .en: "Cloud engine isn't set up; using the macOS engine for now",
            .ja: "クラウドエンジンが未設定のため、macOS 標準エンジンを使用中",
            .ko: "클라우드 엔진이 설정되지 않아 macOS 기본 엔진을 사용합니다",
            .zhCN: "云端引擎尚未设置,暂用 macOS 原生引擎"],
        "已切換麥克風為「%@」,你軌(右)會有短暫空白": [
            .en: "Switched mic to \u{201C}%@\u{201D} — your track (right) will have a short gap",
            .ja: "マイクを「%@」に切り替えました。あなたのトラック(右)に短い空白が入ります",
            .ko: "마이크를 \u{201C}%@\u{201D}(으)로 전환했습니다 — 내 트랙(오른쪽)에 짧은 공백이 생깁니다",
            .zhCN: "已切换麦克风为「%@」,你轨(右)会有短暂空白"],
        "⚠️ 切換到「%@」失敗、原麥克風也起不來,你軌(右)現在收不到音 — 請停止錄音、重選裝置再錄": [
            .en: "⚠️ Couldn't switch to \u{201C}%@\u{201D} and the previous mic won't restart — your track (right) isn't recording. Stop, pick a device, and record again",
            .ja: "⚠️「%@」への切り替えに失敗し、元のマイクも起動しません。あなたのトラック(右)は録れていません — 録音を停止し、デバイスを選び直してください",
            .ko: "⚠️ \u{201C}%@\u{201D}(으)로 전환하지 못했고 기존 마이크도 다시 시작되지 않습니다. 내 트랙(오른쪽)이 녹음되지 않습니다 — 녹음을 멈추고 장치를 다시 선택하세요",
            .zhCN: "⚠️ 切换到「%@」失败、原麦克风也起不来,你轨(右)现在收不到音 — 请停止录音、重选设备再录"],
        "偵測到你的麥克風中斷(%@),已自動重接「%@」": [
            .en: "Your mic dropped out (%@) — reconnected to \u{201C}%@\u{201D}",
            .ja: "マイクが途切れました(%@)。「%@」に自動で再接続しました",
            .ko: "마이크가 끊겼습니다(%@) — \u{201C}%@\u{201D}에 자동으로 다시 연결했습니다",
            .zhCN: "检测到你的麦克风中断(%@),已自动重连「%@」"],
        "已嘗試自動重建對方軌,但可能仍收不到 — 若用藍牙耳機當輸出會走 HFP/電話模式而擷取不到,請改用內建喇叭或有線輸出": [
            .en: "Tried to restart their track, but it may still be silent — Bluetooth headphones as output switch to HFP (call mode) and can't be captured; use built-in speakers or wired output",
            .ja: "相手トラックの再構築を試みましたが、まだ録れていない可能性があります — Bluetooth イヤホンを出力にすると HFP(通話モード)になり取得できません。内蔵スピーカーか有線出力にしてください",
            .ko: "상대방 트랙을 다시 시작했지만 여전히 안 들어올 수 있습니다 — 블루투스 이어폰을 출력으로 쓰면 HFP(통화 모드)로 전환되어 캡처할 수 없습니다. 내장 스피커나 유선 출력을 사용하세요",
            .zhCN: "已尝试自动重建对方轨,但可能仍收不到 — 若用蓝牙耳机当输出会走 HFP/电话模式而采集不到,请改用内置扬声器或有线输出"],
        "偵測到系統音訊擷取中斷(%@),已自動重新啟動": [
            .en: "System audio capture was interrupted (%@) — restarted automatically",
            .ja: "システム音声のキャプチャが中断しました(%@) — 自動的に再起動しました",
            .ko: "시스템 오디오 캡처가 중단되었습니다(%@) — 자동으로 다시 시작했습니다",
            .zhCN: "检测到系统音频采集中断(%@),已自动重新启动"],
        "⚠️ 你選的是藍牙麥克風,整場可能收不到聲音(常被會議 app 佔住或掉窄頻)— 請到設定改用內建或 USB 麥克風": [
            .en: "⚠️ You're using a Bluetooth mic — it may capture nothing for the whole meeting (meeting apps often grab it or drop it to narrowband). Switch to a built-in or USB mic in Settings",
            .ja: "⚠️ Bluetooth マイクを選んでいます。会議アプリに占有されたり狭帯域になったりして、全編録れないことがあります — 設定で内蔵か USB マイクに変更してください",
            .ko: "⚠️ 블루투스 마이크를 선택했습니다. 회의 앱이 점유하거나 협대역으로 떨어져 전체가 녹음되지 않을 수 있습니다 — 설정에서 내장 또는 USB 마이크로 바꾸세요",
            .zhCN: "⚠️ 你选的是蓝牙麦克风,整场可能收不到声音(常被会议 app 占住或掉窄频)— 请到设置改用内置或 USB 麦克风"],
        // AUD-38(#2529):藍牙麥震盪鎖橫幅。
        "⚠️ 藍牙麥克風「%@」在此系統無法穩定擷取（HFP 格式反覆切換），你軌（右）已停止自動重建 — 請切回內建或有線麥克風": [
            .en: "⚠️ The Bluetooth mic \u{201C}%@\u{201D} can't capture reliably on this Mac (its HFP format keeps switching) — auto-reconnect for your track (right) has stopped. Switch back to the built-in or a wired mic",
            .ja: "⚠️ Bluetooth マイク「%@」はこの Mac では安定して録音できません(HFP のフォーマットが切り替わり続けています)。あなたのトラック(右)の自動再接続を停止しました — 内蔵か有線マイクに戻してください",
            .ko: "⚠️ 블루투스 마이크 \u{201C}%@\u{201D}는 이 Mac에서 안정적으로 녹음할 수 없습니다(HFP 형식이 계속 바뀜). 내 트랙(오른쪽)의 자동 재연결을 중단했습니다 — 내장 또는 유선 마이크로 바꾸세요",
            .zhCN: "⚠️ 蓝牙麦克风「%@」在此系统无法稳定采集（HFP 格式反复切换），你轨（右）已停止自动重建 — 请切回内置或有线麦克风"],
        "你的麥克風似乎沒收到聲音 — 請到設定確認「你的麥克風」選對裝置": [
            .en: "Your mic doesn't seem to pick up sound — check \u{201C}Your mic\u{201D} in Settings",
            .ja: "マイクが音を拾っていないようです — 設定の「あなたのマイク」で正しいデバイスか確認してください",
            .ko: "마이크가 소리를 받지 못하는 것 같습니다 — 설정의 \u{2018}내 마이크\u{2019}에서 장치를 확인하세요",
            .zhCN: "你的麦克风似乎没收到声音 — 请到设置确认「你的麦克风」选对设备"],
        "⚠️ 對方(系統音訊)沒收到聲音 — 若用藍牙耳機當輸出,通話會走 HFP/電話模式而擷取不到對方,請改用內建喇叭或有線輸出;並確認會議音訊在這台 Mac 上播放": [
            .en: "⚠️ No sound from Them (system audio) — Bluetooth headphones as output switch calls to HFP (call mode), which can't be captured. Use built-in speakers or wired output, and make sure the meeting audio plays on this Mac",
            .ja: "⚠️ 相手(システム音声)の音が入っていません — Bluetooth イヤホンを出力にすると通話が HFP(通話モード)になり取得できません。内蔵スピーカーか有線出力にし、会議の音声がこの Mac で再生されているか確認してください",
            .ko: "⚠️ 상대방(시스템 오디오) 소리가 들어오지 않습니다 — 블루투스 이어폰을 출력으로 쓰면 통화가 HFP(통화 모드)로 전환되어 캡처할 수 없습니다. 내장 스피커나 유선 출력을 쓰고, 회의 오디오가 이 Mac에서 재생되는지 확인하세요",
            .zhCN: "⚠️ 对方(系统音频)没收到声音 — 若用蓝牙耳机当输出,通话会走 HFP/电话模式而采集不到对方,请改用内置扬声器或有线输出;并确认会议音频在这台 Mac 上播放"],
        "偵測到音訊裝置變更,錄音續行中,請確認狀態": [
            .en: "Audio device changed — still recording. Please check your setup",
            .ja: "オーディオデバイスの変更を検出しました。録音は継続中です — 状態をご確認ください",
            .ko: "오디오 장치가 변경되었습니다. 녹음은 계속됩니다 — 상태를 확인하세요",
            .zhCN: "检测到音频设备变更,录音继续中,请确认状态"],
        // 警示訊息裡的原因(括號內)與裝置名 fallback
        "你軌訊號中斷": [.en: "signal lost", .ja: "信号が途切れました", .ko: "신호 끊김", .zhCN: "你轨信号中断"],
        "選用的麥克風已移除": [.en: "selected mic was removed", .ja: "選択中のマイクが取り外されました", .ko: "선택한 마이크가 제거됨", .zhCN: "选用的麦克风已移除"],
        "對方軌訊號中斷": [.en: "signal lost", .ja: "信号が途切れました", .ko: "신호 끊김", .zhCN: "对方轨信号中断"],
        "對方軌持續無聲": [.en: "silent for too long", .ja: "無音が続いています", .ko: "계속 무음", .zhCN: "对方轨持续无声"],
        "系統輸出裝置變更": [.en: "output device changed", .ja: "出力デバイスが変更されました", .ko: "출력 장치 변경", .zhCN: "系统输出设备变更"],
        "系統預設": [.en: "System Default", .ja: "システムのデフォルト", .ko: "시스템 기본값", .zhCN: "系统默认"],
        // 設定頁 Core 標籤(Eric 2026-09-17 A2 / 2026-09-18 D1)
        "跟隨系統": [.en: "Follow system", .ja: "システムに従う", .ko: "시스템 따름", .zhCN: "跟随系统"],
        "macOS 原生(即時·本機)": [.en: "macOS native (live · on-device)", .ja: "macOS 標準(リアルタイム・端末内)", .ko: "macOS 기본(실시간 · 온디바이스)", .zhCN: "macOS 原生(实时·本机)"],
        "Whisper(高精度·本機)": [.en: "Whisper (high accuracy · on-device)", .ja: "Whisper(高精度・端末内)", .ko: "Whisper(고정밀 · 온디바이스)", .zhCN: "Whisper(高精度·本机)"],
        "雲端(自帶 API)": [.en: "Cloud (your own API key)", .ja: "クラウド(自分の API)", .ko: "클라우드(자체 API)", .zhCN: "云端(自带 API)"],
        "large-v3-turbo(建議·1.6GB·快)": [.en: "large-v3-turbo (recommended · 1.6GB · fast)", .ja: "large-v3-turbo(推奨・1.6GB・高速)", .ko: "large-v3-turbo(권장 · 1.6GB · 빠름)", .zhCN: "large-v3-turbo(建议·1.6GB·快)"],
        "large-v3-q5_0(高精度·1.1GB)": [.en: "large-v3-q5_0 (high accuracy · 1.1GB)", .ja: "large-v3-q5_0(高精度・1.1GB)", .ko: "large-v3-q5_0(고정밀 · 1.1GB)", .zhCN: "large-v3-q5_0(高精度·1.1GB)"],
        "large-v3(最高精度·3.1GB)": [.en: "large-v3 (highest accuracy · 3.1GB)", .ja: "large-v3(最高精度・3.1GB)", .ko: "large-v3(최고 정밀 · 3.1GB)", .zhCN: "large-v3(最高精度·3.1GB)"],
        // QUIT-12/13(#1697):轉稿中退出的確認框與「上次未完成」標記
        // (zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文,比照既有翻譯表慣例)
        "逐字稿還在轉檔中": [
            .en: "A transcript is still being generated",
            .ja: "文字起こしがまだ実行中です",
            .ko: "받아쓰기가 아직 진행 중입니다",
            .zhCN: "字幕还在转写中"],
        "現在離開會中斷這次轉稿(沒有續傳,下次要整段重轉)。錄音檔會留著。": [
            .en: "Quitting now cancels it — there's no resume, so it starts over next time. Your recording is kept.",
            .ja: "今終了するとこの文字起こしは中断されます(再開はできず、次回は最初からやり直しです)。録音ファイルは残ります。",
            .ko: "지금 종료하면 이 받아쓰기가 중단됩니다(이어하기가 없어 다음에는 처음부터 다시 합니다). 녹음 파일은 남습니다.",
            .zhCN: "现在离开会中断这次转写(没有续传,下次要整段重转)。录音文件会留着。"],
        "繼續轉稿": [.en: "Keep Transcribing", .ja: "文字起こしを続ける", .ko: "계속 받아쓰기", .zhCN: "继续转写"],
        "中斷並離開": [.en: "Cancel & Quit", .ja: "中断して終了", .ko: "중단하고 종료", .zhCN: "中断并离开"],
        "上次未完成": [.en: "Unfinished last time", .ja: "前回は未完了", .ko: "지난번 미완료", .zhCN: "上次未完成"],
        // #2417 逐字稿校正層(zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文,比照既有翻譯表慣例)
        "逐字稿校正": [.en: "Transcript correction", .ja: "文字起こしの校正", .ko: "받아쓰기 교정", .zhCN: "逐字稿校正"],
        "關閉": [.en: "Off", .ja: "オフ", .ko: "끄기", .zhCN: "关闭"],
        "Claude CLI(本機)": [.en: "Claude CLI (this Mac)", .ja: "Claude CLI(この Mac)", .ko: "Claude CLI(이 Mac)", .zhCN: "Claude CLI(本机)"],
        "本地假供應商(測試用)": [.en: "Local fake provider (testing)", .ja: "ローカル擬似プロバイダ(テスト用)", .ko: "로컬 가짜 제공자(테스트용)", .zhCN: "本地假供应商(测试用)"],
        "本地模型(尚未提供)": [.en: "Local model (not yet available)", .ja: "ローカルモデル(未提供)", .ko: "로컬 모델(아직 없음)", .zhCN: "本地模型(尚未提供)"],
        "檢查逐字稿": [.en: "Check Transcript", .ja: "文字起こしをチェック", .ko: "받아쓰기 검토", .zhCN: "检查逐字稿"],
        "接受": [.en: "Accept", .ja: "採用", .ko: "적용", .zhCN: "接受"],
        "忽略": [.en: "Ignore", .ja: "無視", .ko: "무시", .zhCN: "忽略"],
        "還原": [.en: "Undo", .ja: "元に戻す", .ko: "되돌리기", .zhCN: "还原"],
        "全部忽略": [.en: "Ignore All", .ja: "すべて無視", .ko: "모두 무시", .zhCN: "全部忽略"],
        "建議 %@ 則": [.en: "%@ suggestions", .ja: "提案 %@ 件", .ko: "제안 %@건", .zhCN: "建议 %@ 则"],
        "第 %@ 段": [.en: "Segment %@", .ja: "第 %@ 段", .ko: "%@번째 단락", .zhCN: "第 %@ 段"],
        "開啟後,按「檢查逐字稿」會把逐字稿文字交給這台電腦上的 Claude Code 送到 Anthropic,用你自己的訂閱額度;不送音訊、檔名與會議名稱。": [
            .en: "When on, “Check Transcript” hands the transcript text to Claude Code on this Mac, which sends it to Anthropic using your own subscription. Audio, file names and meeting names are never sent.",
            .ja: "オンにすると「文字起こしをチェック」でこの Mac 上の Claude Code に文字起こしのテキストを渡し、あなた自身のサブスクリプションで Anthropic に送信します。音声・ファイル名・会議名は送信しません。",
            .ko: "켜면 ‘받아쓰기 검토’가 이 Mac의 Claude Code에 받아쓰기 텍스트를 넘기고, 본인 구독으로 Anthropic에 전송합니다. 오디오, 파일 이름, 회의 이름은 보내지 않습니다.",
            .zhCN: "开启后,按「检查逐字稿」会把逐字稿文字交给这台电脑上的 Claude Code 送到 Anthropic,用你自己的订阅额度;不送音频、文件名与会议名称。"],
        "要開啟逐字稿校正嗎?": [.en: "Turn on transcript correction?", .ja: "文字起こしの校正をオンにしますか?", .ko: "받아쓰기 교정을 켤까요?", .zhCN: "要开启逐字稿校正吗?"],
        "開啟": [.en: "Turn On", .ja: "オンにする", .ko: "켜기", .zhCN: "开启"],
        "找不到 claude 指令,請先安裝 Claude Code": [.en: "Can't find the claude command — install Claude Code first", .ja: "claude コマンドが見つかりません。先に Claude Code をインストールしてください", .ko: "claude 명령을 찾을 수 없습니다. 먼저 Claude Code를 설치하세요", .zhCN: "找不到 claude 命令,请先安装 Claude Code"],
        "Claude Code 尚未登入,請在終端機執行 claude /login": [.en: "Claude Code isn't logged in — run claude /login in Terminal", .ja: "Claude Code が未ログインです。ターミナルで claude /login を実行してください", .ko: "Claude Code에 로그인되어 있지 않습니다. 터미널에서 claude /login 을 실행하세요", .zhCN: "Claude Code 尚未登录,请在终端执行 claude /login"],
        "已找到 Claude Code,已登入": [.en: "Claude Code found and logged in", .ja: "Claude Code を検出、ログイン済み", .ko: "Claude Code 확인됨, 로그인됨", .zhCN: "已找到 Claude Code,已登录"],
        // #2438 M6 設定頁「模型」區段(T3／E／G1;zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文,比照既有翻譯表慣例)
        // #2438 Phase 2 會議記錄真後端(MIN-05／07／09;zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文)
        "開啟 Claude CLI(本機)": [.en: "Turn on Claude CLI (local)", .ja: "Claude CLI(ローカル)をオンにする", .ko: "Claude CLI(로컬) 켜기", .zhCN: "开启 Claude CLI(本机)"],
        "要開啟這個後端嗎?": [.en: "Turn on this backend?", .ja: "このバックエンドをオンにしますか?", .ko: "이 백엔드를 켤까요?", .zhCN: "要开启这个后端吗?"],
        "這個後端會把文字交給這台電腦上的 Claude Code,再送到 Anthropic,用你自己的訂閱額度。各功能送出的內容:": [
            .en: "This backend hands text to Claude Code on this Mac, which sends it to Anthropic using your own subscription. What each feature sends:",
            .ja: "このバックエンドはテキストをこの Mac 上の Claude Code に渡し、あなたのサブスクリプションで Anthropic に送信します。各機能が送る内容:",
            .ko: "이 백엔드는 텍스트를 이 Mac의 Claude Code에 넘기고, 본인 구독으로 Anthropic에 전송합니다. 기능별 전송 내용:",
            .zhCN: "这个后端会把文字交给这台电脑上的 Claude Code,再送到 Anthropic,用你自己的订阅额度。各功能送出的内容:"],
        "• 逐字稿校正:按「檢查逐字稿」時,該批逐字稿的段號與文字。": [
            .en: "• Transcript correction: when you press “Check Transcript”, the segment numbers and text of that batch.",
            .ja: "• 文字起こしの校正:「文字起こしをチェック」を押したとき、そのバッチの段落番号とテキスト。",
            .ko: "• 받아쓰기 교정: ‘받아쓰기 검토’를 누를 때 해당 묶음의 단락 번호와 텍스트.",
            .zhCN: "• 逐字稿校正:按「检查逐字稿」时,该批逐字稿的段号与文字。"],
        "• 會議記錄:每次更新時,上一版會議記錄、自上次之後的逐字稿(含「你／對方」標籤與時間)、筆記全文(含你寫的標題)。": [
            .en: "• Meeting minutes: on every update, the previous minutes, the transcript since the last update (with “You/Them” labels and times), and the full text of your notes (including the title you wrote).",
            .ja: "• 議事録:更新ごとに、前回の議事録、前回以降の文字起こし(「あなた/相手」ラベルと時刻を含む)、メモの全文(あなたが書いたタイトルを含む)。",
            .ko: "• 회의록: 업데이트마다 이전 회의록, 마지막 업데이트 이후의 받아쓰기(‘나/상대’ 라벨과 시간 포함), 메모 전문(직접 쓴 제목 포함).",
            .zhCN: "• 会议记录:每次更新时,上一版会议记录、自上次之后的逐字稿(含「你／对方」标签与时间)、笔记全文(含你写的标题)。"],
        "一律不送:音訊、檔名、路徑、錄音日期與裝置名稱。": [
            .en: "Never sent: audio, file names, paths, recording date, or device names.",
            .ja: "送信しないもの:音声、ファイル名、パス、録音日、デバイス名。",
            .ko: "전송하지 않는 것: 오디오, 파일 이름, 경로, 녹음 날짜, 기기 이름.",
            .zhCN: "一律不送:音频、文件名、路径、录音日期与设备名称。"],
        "會議記錄更新逾時,請稍後再試": [.en: "Minutes update timed out — try again later", .ja: "議事録の更新がタイムアウトしました。後でもう一度お試しください", .ko: "회의록 업데이트 시간이 초과되었습니다. 잠시 후 다시 시도하세요", .zhCN: "会议记录更新超时,请稍后再试"],
        "會議記錄回應無法解析:%@": [.en: "Couldn't read the minutes response: %@", .ja: "議事録の応答を解析できません:%@", .ko: "회의록 응답을 해석할 수 없습니다: %@", .zhCN: "会议记录回应无法解析:%@"],
        "會議記錄更新失敗(exit %@):%@": [.en: "Minutes update failed (exit %@): %@", .ja: "議事録の更新に失敗しました(exit %@):%@", .ko: "회의록 업데이트 실패(exit %@): %@", .zhCN: "会议记录更新失败(exit %@):%@"],
        "自動更新已連續失敗 %@ 次,已暫停;按「立即更新」重試": [.en: "Auto-update failed %@ times in a row and is paused — press “Update Now” to retry", .ja: "自動更新が %@ 回連続で失敗したため一時停止しました。「今すぐ更新」で再試行してください", .ko: "자동 업데이트가 %@회 연속 실패하여 일시 중지되었습니다. ‘지금 업데이트’로 다시 시도하세요", .zhCN: "自动更新已连续失败 %@ 次,已暂停;按「立即更新」重试"],
        "這場還沒有逐字稿,先轉逐字稿再產生會議記錄": [.en: "No transcript for this recording yet — transcribe it first, then generate minutes", .ja: "この録音にはまだ文字起こしがありません。先に文字起こしをしてから議事録を生成してください", .ko: "이 녹음에는 아직 받아쓰기가 없습니다. 먼저 받아쓰기한 뒤 회의록을 생성하세요", .zhCN: "这场还没有逐字稿,先转逐字稿再生成会议记录"],
        "模型": [.en: "Models", .ja: "モデル", .ko: "모델", .zhCN: "模型"],
        "每個功能各自選後端;預設全部關閉,沒選後端的功能不會出現。": [.en: "Each feature picks its own backend. All are off by default; a feature with no backend doesn't appear.", .ja: "機能ごとにバックエンドを選びます。既定はすべてオフで、バックエンド未選択の機能は表示されません。", .ko: "기능마다 백엔드를 따로 고릅니다. 기본은 모두 꺼짐이며, 백엔드를 고르지 않은 기능은 나타나지 않습니다.", .zhCN: "每个功能各自选后端;默认全部关闭,没选后端的功能不会出现。"],
        "要開啟會議記錄嗎?": [.en: "Turn on meeting minutes?", .ja: "議事録をオンにしますか?", .ko: "회의록을 켤까요?", .zhCN: "要开启会议记录吗?"],
        "開啟後,每次更新會議記錄都會把逐字稿與筆記全文交給這台電腦上的 Claude Code 送到 Anthropic,用你自己的訂閱額度;不送音訊與檔名。": [
            .en: "When on, every minutes update hands the transcript and the full text of your notes to Claude Code on this Mac, which sends them to Anthropic using your own subscription. Audio and file names are never sent.",
            .ja: "オンにすると、議事録を更新するたびに文字起こしとメモの全文をこの Mac 上の Claude Code に渡し、あなた自身のサブスクリプションで Anthropic に送信します。音声とファイル名は送信しません。",
            .ko: "켜면 회의록을 업데이트할 때마다 받아쓰기와 메모 전문을 이 Mac의 Claude Code에 넘기고, 본인 구독으로 Anthropic에 전송합니다. 오디오와 파일 이름은 보내지 않습니다.",
            .zhCN: "开启后,每次更新会议记录都会把逐字稿与笔记全文交给这台电脑上的 Claude Code 送到 Anthropic,用你自己的订阅额度;不送音频与文件名。"],
        "開啟後,資料會送出這台電腦,交給所選的後端處理。": [.en: "When on, data leaves this Mac and is processed by the selected backend.", .ja: "オンにすると、データはこの Mac の外に送られ、選択したバックエンドで処理されます。", .ko: "켜면 데이터가 이 Mac 밖으로 전송되어 선택한 백엔드에서 처리됩니다.", .zhCN: "开启后,数据会发送到这台电脑之外,交给所选的后端处理。"],
        "Claude CLI 模型檔位（校正與會議記錄共用）": [.en: "Claude CLI model (shared by correction and minutes)", .ja: "Claude CLI のモデル(校正と議事録で共通)", .ko: "Claude CLI 모델(교정·회의록 공통)", .zhCN: "Claude CLI 模型档位（校正与会议记录共用）"],
        // #2418 Codex CLI 後端(CDX-01/03/06/08;zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文,比照既有翻譯表慣例)
        "Codex CLI(本機)": [.en: "Codex CLI (this Mac)", .ja: "Codex CLI(この Mac)", .ko: "Codex CLI(이 Mac)", .zhCN: "Codex CLI(本机)"],
        "開啟 Codex CLI(本機)": [.en: "Turn on Codex CLI (local)", .ja: "Codex CLI(ローカル)をオンにする", .ko: "Codex CLI(로컬) 켜기", .zhCN: "开启 Codex CLI(本机)"],
        "這個後端會把文字交給這台電腦上的 Codex CLI,再送到 OpenAI,用你自己的 ChatGPT 訂閱額度。各功能送出的內容:": [
            .en: "This backend hands text to Codex CLI on this Mac, which sends it to OpenAI using your own ChatGPT subscription. What each feature sends:",
            .ja: "このバックエンドはテキストをこの Mac 上の Codex CLI に渡し、あなたの ChatGPT サブスクリプションで OpenAI に送信します。各機能が送る内容:",
            .ko: "이 백엔드는 텍스트를 이 Mac의 Codex CLI에 넘기고, 본인 ChatGPT 구독으로 OpenAI에 전송합니다. 기능별 전송 내용:",
            .zhCN: "这个后端会把文字交给这台电脑上的 Codex CLI,再送到 OpenAI,用你自己的 ChatGPT 订阅额度。各功能送出的内容:"],
        "開啟後,按「檢查逐字稿」會把逐字稿文字交給這台電腦上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 訂閱額度;不送音訊、檔名與會議名稱。": [
            .en: "When on, “Check Transcript” hands the transcript text to Codex CLI on this Mac, which sends it to OpenAI using your own ChatGPT subscription; no audio, file names or meeting titles are sent.",
            .ja: "オンにすると、「文字起こしをチェック」で文字起こしのテキストをこの Mac 上の Codex CLI に渡し、あなたの ChatGPT サブスクリプションで OpenAI に送信します。音声・ファイル名・会議名は送りません。",
            .ko: "켜면 ‘받아쓰기 검토’ 시 받아쓰기 텍스트를 이 Mac의 Codex CLI에 넘기고, 본인 ChatGPT 구독으로 OpenAI에 전송합니다. 오디오, 파일 이름, 회의 이름은 보내지 않습니다.",
            .zhCN: "开启后,按「检查逐字稿」会把逐字稿文字交给这台电脑上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 订阅额度;不送音频、文件名与会议名称。"],
        "開啟後,每次更新會議記錄都會把逐字稿與筆記全文交給這台電腦上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 訂閱額度;不送音訊與檔名。": [
            .en: "When on, every minutes update hands the transcript and your full notes to Codex CLI on this Mac, which sends them to OpenAI using your own ChatGPT subscription; no audio or file names are sent.",
            .ja: "オンにすると、議事録を更新するたびに文字起こしとメモ全文をこの Mac 上の Codex CLI に渡し、あなたの ChatGPT サブスクリプションで OpenAI に送信します。音声とファイル名は送りません。",
            .ko: "켜면 회의록을 업데이트할 때마다 받아쓰기와 메모 전문을 이 Mac의 Codex CLI에 넘기고, 본인 ChatGPT 구독으로 OpenAI에 전송합니다. 오디오와 파일 이름은 보내지 않습니다.",
            .zhCN: "开启后,每次更新会议记录都会把逐字稿与笔记全文交给这台电脑上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 订阅额度;不送音频与文件名。"],
        "找不到 codex 指令,請先安裝 Codex CLI": [.en: "Can't find the codex command — install Codex CLI first", .ja: "codex コマンドが見つかりません。先に Codex CLI をインストールしてください", .ko: "codex 명령을 찾을 수 없습니다. 먼저 Codex CLI를 설치하세요", .zhCN: "找不到 codex 指令,请先安装 Codex CLI"],
        "Codex CLI 尚未登入,請在終端機執行 codex login": [.en: "Codex CLI isn't logged in — run codex login in Terminal", .ja: "Codex CLI が未ログインです。ターミナルで codex login を実行してください", .ko: "Codex CLI가 로그인되지 않았습니다. 터미널에서 codex login을 실행하세요", .zhCN: "Codex CLI 尚未登录,请在终端执行 codex login"],
        "已找到 Codex CLI,已登入": [.en: "Codex CLI found and logged in", .ja: "Codex CLI を検出、ログイン済み", .ko: "Codex CLI 확인됨, 로그인됨", .zhCN: "已找到 Codex CLI,已登录"],
        "Codex CLI 模型檔位（校正與會議記錄共用）": [.en: "Codex CLI model (shared by correction and minutes)", .ja: "Codex CLI のモデル(校正と議事録で共通)", .ko: "Codex CLI 모델(교정·회의록 공통)", .zhCN: "Codex CLI 模型档位（校正与会议记录共用）"],
        // UI-60 建議列跳逐字稿(zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文)
        "原句已不在稿內": [.en: "The original sentence is no longer in the transcript", .ja: "元の文はもう文字起こしにありません", .ko: "원문 문장이 더 이상 받아쓰기에 없습니다", .zhCN: "原句已不在稿内"],
        "Codex CLI:文字會送到 OpenAI": [.en: "Codex CLI: text is sent to OpenAI", .ja: "Codex CLI:テキストは OpenAI に送信されます", .ko: "Codex CLI: 텍스트가 OpenAI로 전송됩니다", .zhCN: "Codex CLI:文字会发送到 OpenAI"],
        // #2612 逐字稿翻譯(TRL;zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文,比照既有翻譯表慣例)
        // #2623 每場模型用量(TOK;zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體譯文)
        "用量": [.en: "usage", .ja: "使用量", .ko: "사용량", .zhCN: "用量"],
        "模型用量…": [.en: "Model Usage…", .ja: "モデル使用量…", .ko: "모델 사용량…", .zhCN: "模型用量…"],
        "模型用量": [.en: "Model usage", .ja: "モデル使用量", .ko: "모델 사용량", .zhCN: "模型用量"],
        "本場模型用量": [.en: "Model usage this session", .ja: "この回のモデル使用量", .ko: "이번 회의 모델 사용량", .zhCN: "本场模型用量"],
        "校正": [.en: "Correction", .ja: "校正", .ko: "교정", .zhCN: "校正"],
        "翻譯": [.en: "Translation", .ja: "翻訳", .ko: "번역", .zhCN: "翻译"],
        "全場合計": [.en: "Session total", .ja: "合計", .ko: "전체 합계", .zhCN: "全场合计"],
        "進 %@／出 %@／%@ 次": [.en: "in %@ / out %@ / %@ calls", .ja: "入力 %@／出力 %@／%@ 回", .ko: "입력 %@／출력 %@／%@회", .zhCN: "进 %@／出 %@／%@ 次"],
        "打開 tokens.json": [.en: "Open tokens.json", .ja: "tokens.json を開く", .ko: "tokens.json 열기", .zhCN: "打开 tokens.json"],
        "這場還沒有模型用量": [.en: "No model usage recorded for this session yet", .ja: "この回のモデル使用量はまだありません", .ko: "이번 회의의 모델 사용량이 아직 없습니다", .zhCN: "这场还没有模型用量"],
        "好": [.en: "OK", .ja: "OK", .ko: "확인", .zhCN: "好"],
        "逐字稿翻譯": [.en: "Transcript translation", .ja: "文字起こしの翻訳", .ko: "받아쓰기 번역", .zhCN: "逐字稿翻译"],
        "Apple 翻譯(本機)": [.en: "Apple Translate (this Mac)", .ja: "Apple 翻訳(この Mac)", .ko: "Apple 번역(이 Mac)", .zhCN: "Apple 翻译(本机)"],
        "Apple 翻譯:資料不出機": [.en: "Apple Translate: nothing leaves this Mac", .ja: "Apple 翻訳:データはこの Mac から出ません", .ko: "Apple 번역: 데이터가 이 Mac을 벗어나지 않습니다", .zhCN: "Apple 翻译:数据不出机"],
        "Apple 翻譯目前無法使用": [.en: "Apple Translate is currently unavailable", .ja: "Apple 翻訳は現在利用できません", .ko: "Apple 번역을 현재 사용할 수 없습니다", .zhCN: "Apple 翻译目前无法使用"],
        "目標語言": [.en: "Target language", .ja: "翻訳先の言語", .ko: "대상 언어", .zhCN: "目标语言"],
        "送出節奏": [.en: "Send every", .ja: "送信間隔", .ko: "전송 주기", .zhCN: "送出节奏"],
        "30 秒": [.en: "30 seconds", .ja: "30 秒", .ko: "30초", .zhCN: "30 秒"],
        "1 分鐘": [.en: "1 minute", .ja: "1 分", .ko: "1분", .zhCN: "1 分钟"],
        "2 分鐘": [.en: "2 minutes", .ja: "2 分", .ko: "2분", .zhCN: "2 分钟"],
        "5 分鐘": [.en: "5 minutes", .ja: "5 分", .ko: "5분", .zhCN: "5 分钟"],
        "每小時約 %@ 萬 tokens(Codex 每批固定背 13.5k)": [.en: "About %@0k tokens per hour (Codex carries a fixed 13.5k per batch)", .ja: "1 時間あたり約 %@ 万トークン(Codex はバッチごとに固定 13.5k)", .ko: "시간당 약 %@만 토큰(Codex는 배치마다 고정 13.5k)", .zhCN: "每小时约 %@ 万 tokens(Codex 每批固定背 13.5k)"],
        "語言包已安裝": [.en: "Language pack installed", .ja: "言語パックはインストール済み", .ko: "언어 팩 설치됨", .zhCN: "语言包已安装"],
        "需下載語言包": [.en: "Language pack needs downloading", .ja: "言語パックのダウンロードが必要", .ko: "언어 팩 다운로드 필요", .zhCN: "需下载语言包"],
        "下載語言包": [.en: "Download language pack", .ja: "言語パックをダウンロード", .ko: "언어 팩 다운로드", .zhCN: "下载语言包"],
        "辨識語言與目標語言相同,沒有東西可翻": [.en: "Recognition language and target language are the same — nothing to translate", .ja: "認識言語と翻訳先が同じです。翻訳するものがありません", .ko: "인식 언어와 대상 언어가 같아 번역할 것이 없습니다", .zhCN: "识别语言与目标语言相同,没有东西可翻"],
        "此語言組合不支援": [.en: "This language pair isn't supported", .ja: "この言語の組み合わせは非対応", .ko: "이 언어 조합은 지원되지 않습니다", .zhCN: "此语言组合不支持"],
        "檢查語言包中…": [.en: "Checking language pack…", .ja: "言語パックを確認中…", .ko: "언어 팩 확인 중…", .zhCN: "检查语言包中…"],
        "繁體中文": [.en: "Traditional Chinese", .ja: "繁体字中国語", .ko: "번체 중국어", .zhCN: "繁体中文"],
        "英文": [.en: "English", .ja: "英語", .ko: "영어", .zhCN: "英文"],
        "日文": [.en: "Japanese", .ja: "日本語", .ko: "일본어", .zhCN: "日文"],
        "韓文": [.en: "Korean", .ja: "韓国語", .ko: "한국어", .zhCN: "韩文"],
        "簡體中文": [.en: "Simplified Chinese", .ja: "簡体字中国語", .ko: "간체 중국어", .zhCN: "简体中文"],
        "繁中": [.en: "zh-Hant", .ja: "繁中", .ko: "번체", .zhCN: "繁中"],
        "簡中": [.en: "zh-Hans", .ja: "簡中", .ko: "간체", .zhCN: "简中"],
        "譯": [.en: "Translate", .ja: "訳", .ko: "번역", .zhCN: "译"],
        "顯示譯文": [.en: "Show translations", .ja: "訳文を表示", .ko: "번역 표시", .zhCN: "显示译文"],
        "立即翻譯": [.en: "Translate Now", .ja: "今すぐ翻訳", .ko: "지금 번역", .zhCN: "立即翻译"],
        "翻譯整份": [.en: "Translate Whole Transcript", .ja: "全文を翻訳", .ko: "전체 번역", .zhCN: "翻译整份"],
        "重送未譯": [.en: "Retry untranslated", .ja: "未訳を再送", .ko: "미번역 재전송", .zhCN: "重送未译"],
        "未譯": [.en: "untranslated", .ja: "未訳", .ko: "미번역", .zhCN: "未译"],
        "重送這一行": [.en: "Retry this line", .ja: "この行を再送", .ko: "이 줄 재전송", .zhCN: "重送这一行"],
        "逐字稿已更新,譯文需重翻": [.en: "Transcript was updated; translations need redoing", .ja: "文字起こしが更新されました。訳文の再翻訳が必要です", .ko: "받아쓰기가 갱신되어 번역을 다시 해야 합니다", .zhCN: "逐字稿已更新,译文需重翻"],
        "自動翻譯已暫停,按立即翻譯重試": [.en: "Automatic translation paused — press Translate Now to retry", .ja: "自動翻訳を一時停止しました。「今すぐ翻訳」で再試行", .ko: "자동 번역이 일시 중지됨. 지금 번역을 눌러 재시도", .zhCN: "自动翻译已暂停,按立即翻译重试"],
        "翻譯逾時,請稍後再試": [.en: "Translation timed out — try again later", .ja: "翻訳がタイムアウトしました。後でもう一度", .ko: "번역 시간 초과. 나중에 다시 시도하세요", .zhCN: "翻译超时,请稍后再试"],
        "翻譯回應無法解析:%@": [.en: "Couldn't parse the translation response: %@", .ja: "翻訳の応答を解析できません:%@", .ko: "번역 응답을 해석할 수 없습니다: %@", .zhCN: "翻译响应无法解析:%@"],
        "翻譯失敗(exit %@):%@": [.en: "Translation failed (exit %@): %@", .ja: "翻訳に失敗(exit %@):%@", .ko: "번역 실패(exit %@): %@", .zhCN: "翻译失败(exit %@):%@"],
        "開啟後,每批會把自上次之後新定稿行的文字交給這台電腦上的 Claude Code 送到 Anthropic,用你自己的訂閱額度;不送講者、時間、音訊與檔名。": [
            .en: "When on, each batch hands the text of newly finalized lines to Claude Code on this Mac, which sends it to Anthropic using your own subscription; no speakers, times, audio or file names are sent.",
            .ja: "オンにすると、バッチごとに新しく確定した行のテキストをこの Mac 上の Claude Code に渡し、あなたのサブスクリプションで Anthropic に送信します。話者・時刻・音声・ファイル名は送りません。",
            .ko: "켜면 배치마다 새로 확정된 줄의 텍스트를 이 Mac의 Claude Code에 넘기고, 본인 구독으로 Anthropic에 전송합니다. 화자, 시간, 오디오, 파일 이름은 보내지 않습니다.",
            .zhCN: "开启后,每批会把自上次之后新定稿行的文字交给这台电脑上的 Claude Code 送到 Anthropic,用你自己的订阅额度;不送讲者、时间、音频与文件名。"],
        "開啟後,每批會把自上次之後新定稿行的文字交給這台電腦上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 訂閱額度;不送講者、時間、音訊與檔名。": [
            .en: "When on, each batch hands the text of newly finalized lines to Codex CLI on this Mac, which sends it to OpenAI using your own ChatGPT subscription; no speakers, times, audio or file names are sent.",
            .ja: "オンにすると、バッチごとに新しく確定した行のテキストをこの Mac 上の Codex CLI に渡し、あなたの ChatGPT サブスクリプションで OpenAI に送信します。話者・時刻・音声・ファイル名は送りません。",
            .ko: "켜면 배치마다 새로 확정된 줄의 텍스트를 이 Mac의 Codex CLI에 넘기고, 본인 ChatGPT 구독으로 OpenAI에 전송합니다. 화자, 시간, 오디오, 파일 이름은 보내지 않습니다.",
            .zhCN: "开启后,每批会把自上次之后新定稿行的文字交给这台电脑上的 Codex CLI 送到 OpenAI,用你自己的 ChatGPT 订阅额度;不送讲者、时间、音频与文件名。"],
        "• 逐字稿翻譯:每批送出自上次之後新定稿行的文字與目標語言。": [
            .en: "• Transcript translation: each batch sends the text of newly finalized lines and the target language.",
            .ja: "• 文字起こしの翻訳:バッチごとに新しく確定した行のテキストと翻訳先の言語。",
            .ko: "• 받아쓰기 번역: 배치마다 새로 확정된 줄의 텍스트와 대상 언어.",
            .zhCN: "• 逐字稿翻译:每批送出自上次之后新定稿行的文字与目标语言。"],
        "選填,留空跟 CLI 預設走": [.en: "Optional; blank follows the CLI default", .ja: "任意。空欄なら CLI の既定", .ko: "선택 사항, 비우면 CLI 기본값", .zhCN: "选填,留空跟 CLI 默认走"],
        "這個後端的會議記錄功能尚未提供": [.en: "This backend can't produce minutes yet", .ja: "このバックエンドの議事録機能はまだ提供されていません", .ko: "이 백엔드의 회의록 기능은 아직 제공되지 않습니다", .zhCN: "这个后端的会议记录功能尚未提供"],
        "自動更新": [.en: "Update automatically", .ja: "自動更新", .ko: "자동 업데이트", .zhCN: "自动更新"],
        "每 %@ 分鐘更新一次": [.en: "Update every %@ min", .ja: "%@ 分ごとに更新", .ko: "%@분마다 업데이트", .zhCN: "每 %@ 分钟更新一次"],
        "迷你控制列": [.en: "Mini Bar", .ja: "ミニバー", .ko: "미니 바", .zhCN: "迷你控制栏"],
        // #2407 會議提醒(CAL)。文案不帶業務詞:MyParrot 要開源。
        "會議提醒": [.en: "Meeting reminders", .ja: "会議リマインダー", .ko: "회의 알림", .zhCN: "会议提醒"],
        "會議前提醒錄音": [.en: "Remind me to record before meetings", .ja: "会議前に録音を促す", .ko: "회의 전 녹음 알림", .zhCN: "会议前提醒录音"],
        "讀取你勾選的行事曆,會議開始前幾分鐘跳出通知,按一下就開錄。預設關閉;開啟時才會請求行事曆與通知權限。": [.en: "Reads the calendars you tick and shows a notification a few minutes before a meeting; one click starts recording. Off by default; calendar and notification access are requested only when you turn it on.", .ja: "選んだカレンダーを読み、会議の数分前に通知を出します。ワンクリックで録音開始。既定はオフで、オンにした時だけカレンダーと通知の許可を求めます。", .ko: "선택한 캘린더를 읽어 회의 몇 분 전에 알림을 띄우고, 한 번 눌러 녹음을 시작합니다. 기본은 꺼짐이며 켤 때만 캘린더와 알림 권한을 요청합니다.", .zhCN: "读取你勾选的日历,会议开始前几分钟弹出通知,点一下就开录。默认关闭;开启时才会请求日历与通知权限。"],
        "行事曆權限": [.en: "Calendar access", .ja: "カレンダーの許可", .ko: "캘린더 권한", .zhCN: "日历权限"],
        "通知權限": [.en: "Notification access", .ja: "通知の許可", .ko: "알림 권한", .zhCN: "通知权限"],
        "開啟系統設定": [.en: "Open System Settings", .ja: "システム設定を開く", .ko: "시스템 설정 열기", .zhCN: "打开系统设置"],
        "要掃描的日曆": [.en: "Calendars to watch", .ja: "対象カレンダー", .ko: "감시할 캘린더", .zhCN: "要扫描的日历"],
        "讀不到任何日曆": [.en: "No calendars found", .ja: "カレンダーが見つかりません", .ko: "캘린더를 찾을 수 없음", .zhCN: "读不到任何日历"],
        "關鍵字(逗號分隔)": [.en: "Keywords (comma-separated)", .ja: "キーワード(カンマ区切り)", .ko: "키워드(쉼표로 구분)", .zhCN: "关键字(逗号分隔)"],
        "標題含任一關鍵字的事件才提醒。": [.en: "Only events whose title contains one of these keywords are matched.", .ja: "タイトルにいずれかのキーワードを含む予定だけを対象にします。", .ko: "제목에 키워드 중 하나가 포함된 일정만 알립니다.", .zhCN: "标题含任一关键字的事件才提醒。"],
        "提前 %@ 分鐘提醒": [.en: "Remind %@ min before", .ja: "%@ 分前に通知", .ko: "%@분 전에 알림", .zhCN: "提前 %@ 分钟提醒"],
        "外部通知指令(選填)": [.en: "External notify command (optional)", .ja: "外部通知コマンド(任意)", .ko: "외부 알림 명령(선택)", .zhCN: "外部通知命令(选填)"],
        "到點時用 /bin/sh 執行這一行;環境變數 MYPARROT_EVENT_TITLE、MYPARROT_START_ISO、MYPARROT_START_LOCAL、MYPARROT_START_TAIPEI 帶會議資料。": [.en: "Run with /bin/sh at reminder time; MYPARROT_EVENT_TITLE, MYPARROT_START_ISO, MYPARROT_START_LOCAL and MYPARROT_START_TAIPEI carry the meeting details.", .ja: "通知時刻に /bin/sh で実行します。環境変数 MYPARROT_EVENT_TITLE、MYPARROT_START_ISO、MYPARROT_START_LOCAL、MYPARROT_START_TAIPEI に予定の情報が入ります。", .ko: "알림 시각에 /bin/sh 로 실행합니다. 환경 변수 MYPARROT_EVENT_TITLE, MYPARROT_START_ISO, MYPARROT_START_LOCAL, MYPARROT_START_TAIPEI 에 회의 정보가 담깁니다.", .zhCN: "到点时用 /bin/sh 执行这一行;环境变量 MYPARROT_EVENT_TITLE、MYPARROT_START_ISO、MYPARROT_START_LOCAL、MYPARROT_START_TAIPEI 带会议数据。"],
        "上次讀取": [.en: "Last refresh", .ja: "最終読み込み", .ko: "마지막 읽기", .zhCN: "上次读取"],
        "尚未讀取": [.en: "Not yet", .ja: "まだ", .ko: "아직 없음", .zhCN: "尚未读取"],
        "24 小時內命中": [.en: "Matches in next 24 h", .ja: "24 時間以内の該当", .ko: "24시간 내 일치", .zhCN: "24 小时内命中"],
        "下一場": [.en: "Next", .ja: "次の予定", .ko: "다음", .zhCN: "下一场"],
        "沒有": [.en: "None", .ja: "なし", .ko: "없음", .zhCN: "没有"],
        "立即重新讀取": [.en: "Refresh now", .ja: "今すぐ再読み込み", .ko: "지금 새로 읽기", .zhCN: "立即重新读取"],
        "行事曆未授權": [.en: "Calendar access not granted", .ja: "カレンダーが未許可", .ko: "캘린더 권한 없음", .zhCN: "日历未授权"],
        "%@ 台北 ／ %@ %@": [.en: "%@ Taipei / %@ %@", .ja: "%@ 台北 ／ %@ %@", .ko: "%@ 타이베이 / %@ %@", .zhCN: "%@ 台北 ／ %@ %@"],
        "要開始錄音嗎?": [.en: "Start recording?", .ja: "録音を開始しますか?", .ko: "녹음을 시작할까요?", .zhCN: "要开始录音吗?"],
        "停止錄音": [.en: "Stop recording", .ja: "録音を停止", .ko: "녹음 중지", .zhCN: "停止录音"],
        "已在錄音": [.en: "Already recording", .ja: "すでに録音中", .ko: "이미 녹음 중", .zhCN: "已在录音"],
        "MyParrot 已經在錄音中,沒有另外開錄。": [.en: "MyParrot is already recording; nothing new was started.", .ja: "MyParrot はすでに録音中のため、新たに開始しませんでした。", .ko: "MyParrot이 이미 녹음 중이어서 새로 시작하지 않았습니다.", .zhCN: "MyParrot 已经在录音中,没有另外开录。"],
        "CLI 正在錄音": [.en: "CLI is recording", .ja: "CLI が録音中", .ko: "CLI가 녹음 중", .zhCN: "CLI 正在录音"],
        "myparrot 指令列正在錄音,沒有另外開錄。": [.en: "The myparrot command line is recording; nothing new was started.", .ja: "コマンドライン myparrot が録音中のため、新たに開始しませんでした。", .ko: "명령줄 myparrot이 녹음 중이어서 새로 시작하지 않았습니다.", .zhCN: "myparrot 命令行正在录音,没有另外开录。"],
        "錄音沒有訊號": [.en: "No signal in recording", .ja: "録音に信号がありません", .ko: "녹음에 신호 없음", .zhCN: "录音没有信号"],
        "%@已 %@ 分鐘沒有訊號。": [.en: "%@ has had no signal for %@ min.", .ja: "%@ に %@ 分間信号がありません。", .ko: "%@ %@분 동안 신호가 없습니다.", .zhCN: "%@已 %@ 分钟没有信号。"],
        "好像沒有人在說話": [.en: "Nobody seems to be talking", .ja: "誰も話していないようです", .ko: "아무도 말하지 않는 것 같습니다", .zhCN: "好像没有人在说话"],
        "已經 %@ 分鐘沒有聲音了,要停止錄音嗎?": [.en: "No sound for %@ minutes. Stop recording?", .ja: "%@ 分間音がありません。録音を停止しますか?", .ko: "%@분 동안 소리가 없습니다. 녹음을 중지할까요?", .zhCN: "已经 %@ 分钟没有声音了,要停止录音吗?"],
        // #949 第一段:唯一 writer 仲裁＋收割保護＋GUI／CLI 狀態同步(brief §5.9)。zh-lint-skip:.ja/.zhCN 欄為刻意的日文/簡體原文。
        "已有錄音進行中": [.en: "Another recording is already in progress", .ja: "別の録音が進行中です", .ko: "이미 다른 녹음이 진행 중입니다", .zhCN: "已有录音进行中"],
        "MyParrot app 正在錄音：%@（%@），用 app 或 myparrot stop 結束": [.en: "The MyParrot app is recording: %@ (%@). Stop it in the app or with myparrot stop", .ja: "MyParrot アプリが録音中です：%@（%@）。アプリか myparrot stop で終了してください", .ko: "MyParrot 앱이 녹음 중입니다: %@ (%@). 앱이나 myparrot stop으로 종료하세요", .zhCN: "MyParrot app 正在录音：%@（%@），用 app 或 myparrot stop 结束"],
        "myparrot CLI 正在錄音": [.en: "myparrot CLI is recording", .ja: "myparrot CLI が録音中", .ko: "myparrot CLI가 녹음 중", .zhCN: "myparrot CLI 正在录音"],
        "（無回應）": [.en: " (not responding)", .ja: "（応答なし）", .ko: " (응답 없음)", .zhCN: "（无响应）"],
        "此場由 CLI 錄製，沒有即時逐字稿": [.en: "This session is being recorded by the CLI; no live transcript here", .ja: "この録音は CLI で行われているため、リアルタイム文字起こしはありません", .ko: "이 녹음은 CLI가 하고 있어 실시간 자막이 없습니다", .zhCN: "此场由 CLI 录制，没有实时逐字稿"],
        "未完成錄音，右鍵修復": [.en: "Unfinished recording — right-click to repair", .ja: "未完了の録音 — 右クリックで修復", .ko: "완료되지 않은 녹음 — 우클릭으로 복구", .zhCN: "未完成录音，右键修复"],
        "修復": [.en: "Repair", .ja: "修復", .ko: "복구", .zhCN: "修复"],
        "錄音太短（%@ 幀），已移到隔離區": [.en: "Recording too short (%@ frames); moved to quarantine", .ja: "録音が短すぎます（%@ フレーム）。隔離フォルダに移動しました", .ko: "녹음이 너무 짧습니다(%@ 프레임). 격리 폴더로 옮겼습니다", .zhCN: "录音太短（%@ 帧），已移到隔离区"],
        "已修復": [.en: "Repaired", .ja: "修復済み", .ko: "복구됨", .zhCN: "已修复"],
        "停止": [.en: "Stop", .ja: "停止", .ko: "중지", .zhCN: "停止"],
    ]
}

/// #949:Core 的 `lastError` 是繁中句子(CLI 也用同一句)。已知的幾句在 GUI 依介面語言重組;其他原樣顯示。
@MainActor
enum CoreMessageL10n {
    static func localize(_ message: String) -> String {
        if message == RecordingController.leaseHeldMessage { return L("已有錄音進行中") }
        // 「錄音太短（N 幀），已移到隔離區」⇒ 取出 N 再套翻譯模板
        if message.hasPrefix("錄音太短（"), message.hasSuffix("幀），已移到隔離區") {
            let n = message.dropFirst("錄音太短（".count).dropLast("幀），已移到隔離區".count)
                .trimmingCharacters(in: .whitespaces)
            return Lf("錄音太短（%@ 幀），已移到隔離區", [n])
        }
        return message
    }
}

/// Localize a 繁中 key to the current UI language. Call inside SwiftUI bodies.
@MainActor func L(_ key: String) -> String { Localizer.shared.t(key) }

/// BUG-28:帶 `%@` 參數的 key(警示橫幅)。查表後逐一填值;譯文的佔位符數量與
/// 參數不符就整句退回繁中模板,免得畫面上出現 "%@" 或漏掉裝置名。
@MainActor func Lf(_ key: String, _ args: [String]) -> String {
    let translated = L(key)
    guard L10nFormat.placeholderCount(translated) == args.count else {
        return L10nFormat.fill(key, args)
    }
    return L10nFormat.fill(translated, args)
}
