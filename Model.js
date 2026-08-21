.pragma library

// Display languages: `value` is the storage/API language code, `label` is the
// native name shown in the picker. The omarchy SearchableDropdown reads
// `{value, label}` — using `code` was why "language" persisted as "undefined".
var LANGUAGES = [
  { value: "ar", label: "العربية" },
  { value: "en", label: "English" },
  { value: "fr", label: "Français" },
  { value: "es", label: "Español" },
  { value: "tr", label: "Türkçe" },
  { value: "id", label: "Bahasa Indonesia" },
  { value: "ur", label: "اردو" },
  { value: "bn", label: "বাংলা" },
  { value: "ru", label: "Русский" },
  { value: "zh", label: "中文" }
]

var DEFAULT_LANGUAGE = "en"
var DEFAULT_RECITER = "ar.alafasy"
var CDN_BASE = "https://cdn.islamic.app/quran/audio-surah"
var API_RECITERS = "https://api.islamic.app/v1/audio/reciters"
var API_RECITERS_ENG = "https://www.mp3quran.net/api/v3/reciters?language=eng"
var API_RECITERS_AR = "https://www.mp3quran.net/api/v3/reciters?language=ar"

var STATE_VERSION = 3
var CATALOG_TTL_MS = 24 * 60 * 60 * 1000
// Per-surah cap (~300 MB), shared with the quranctl downloader.
var MAX_SURAH_BYTES = 314572800

// --- playback modes ---
var MODE_SINGLE = "single"       // play one surah, then stop
var MODE_CONTINUE = "continue"   // advance to next surah, stop after 114
var MODE_REPEAT_ONE = "repeat-one"
var MODE_REPEAT_ALL = "repeat-all"
var MODES = [MODE_SINGLE, MODE_CONTINUE, MODE_REPEAT_ONE, MODE_REPEAT_ALL]

// --- UI strings -----------------------------------------------------------
// Full chrome translation: tabs, placeholders, buttons, prompts, errors,
// tooltips. `tr(lang, key)` falls back to English.
var STRINGS = {
  en: {
    tabSurah: "Surah", tabReciter: "Reciter",
    searchSurah: "Search surah (any language)", searchReciter: "Search reciter",
    language: "Language", noSurahSelected: "No surah selected",
    download: "Download", streamOnly: "Stream only", close: "Close",
    downloadPrompt: "Download full mushaf (%1)?",
    downloadDesc: "~2 GB · 114 surahs · plays offline afterwards. You can also stream instead.",
    downloadRemaining: "Download %1 remaining surahs",
    downloading: "Downloading mushaf for %1",
    single: "Single", continue: "Continue", repeatOne: "Repeat one", repeatAll: "Repeat all",
    noResults: "No results for \"%1\"", retry: "Retry",
    noAudio: "No audio available for this reciter",
    reciterLoadFailed: "Couldn't load reciters",
    playbackFailed: "Playback failed. Retry, or stream it instead.",
    downloaded: "Downloaded", partial: "Partial", notDownloaded: "Not downloaded", inLibrary: "In library",
    tooltip: "Quran", nowPlaying: "Now playing · %1",
    surahTabTitle: "Surah", reciterTabTitle: "Reciter",
    verses: "%1 verses", seekHint: "Click to seek",
    invalidInput: "Invalid reciter or surah",
    browse: "Browse", downloadingSurah: "Downloading surah %1",
    clearCache: "Clear cache", cacheSize: "Cache: %1", downloadFailed: "Download failed", cacheClearFailed: "Cache unavailable", setupRequired: "Audio engine missing — run install.sh in the plugin folder",
    mpvMissing: "Playback unavailable — is mpv installed?",
    settings: "Settings", storage: "Storage & Cache", clear: "Clear",
    downloadFolder: "Download folder", libraryFolder: "Local library folder",
    apply: "Apply", reset: "Reset",
    invalidPath: "Invalid path", pathNotWritable: "Folder is not writable", libraryUnreadable: "Folder is not readable",
    libraryHint: "Layout: <folder>/<reciter>/<surah>.mp3",
    loadingReciters: "Loading reciters…",
  },
  ar: {
    tabSurah: "السورة", tabReciter: "القارئ",
    searchSurah: "ابحث عن سورة (بأي لغة)", searchReciter: "ابحث عن قارئ",
    language: "اللغة", noSurahSelected: "لم يتم اختيار سورة",
    download: "تحميل", streamOnly: "بث فقط", close: "إغلاق",
    downloadPrompt: "تحميل المصحف كاملاً (%1)؟",
    downloadDesc: "حوالي 2 جيجا · 114 سورة · يعمل دون اتصال بعد ذلك. يمكنك أيضًا البث بدلاً من ذلك.",
    downloadRemaining: "تنزيل السور المتبقية (%1)",
    downloading: "جارٍ تحميل المصحف لـ %1",
    single: "واحدة", continue: "متابعة", repeatOne: "تكرار السورة", repeatAll: "تكرار الكل",
    noResults: "لا توجد نتائج لـ \"%1\"", retry: "إعادة المحاولة",
    noAudio: "لا يتوفر صوت لهذا القارئ",
    reciterLoadFailed: "تعذّر تحميل القُرّاء",
    loadingReciters: "جارٍ تحميل القُرّاء…",
    playbackFailed: "فشل التشغيل. أعد المحاولة أو قم بالبث.",
    downloaded: "تم التنزيل", partial: "جزئي", notDownloaded: "لم يتم التنزيل", inLibrary: "في المكتبة",
    tooltip: "القرآن", nowPlaying: "قيد التشغيل · %1",
    surahTabTitle: "السورة", reciterTabTitle: "القارئ",
    verses: "%1 آية", seekHint: "انقر للانتقال",
    invalidInput: "قارئ أو سورة غير صالحة",
    browse: "تصفح", downloadingSurah: "جارٍ تحميل السورة %1",
    clearCache: "مسح التخزين المؤقت", cacheSize: "التخزين المؤقت: %1", downloadFailed: "فشل التنزيل", cacheClearFailed: "ذاكرة التخزين المؤقت غير متاحة", setupRequired: "محرك الصوت مفقود — شغّل install.sh في مجلد الإضافة",
    mpvMissing: "التشغيل غير متاح — هل mpv مثبّت؟",
    settings: "الإعدادات", storage: "التخزين والذاكرة", clear: "مسح",
    downloadFolder: "مجلد التنزيل", libraryFolder: "مجلد المكتبة المحلية",
    apply: "تطبيق", reset: "استعادة",
    invalidPath: "مسار غير صالح", pathNotWritable: "المجلد غير قابل للكتابة", libraryUnreadable: "المجلد غير قابل للقراءة",
    libraryHint: "الترتيب: <مجلد>/<قارئ>/<سورة>.mp3",
  },
  fr: {
    tabSurah: "Sourate", tabReciter: "Récitant",
    searchSurah: "Rechercher une sourate (toute langue)", searchReciter: "Rechercher un récitant",
    language: "Langue", noSurahSelected: "Aucune sourate sélectionnée",
    download: "Télécharger", streamOnly: "Streaming uniquement", close: "Fermer",
    downloadPrompt: "Télécharger le mushaf complet (%1) ?",
    downloadDesc: "~2 Go · 114 sourates · écoute hors ligne ensuite. Le streaming reste possible.",
    downloadRemaining: "Télécharger les %1 sourates restantes",
    downloading: "Téléchargement du mushaf pour %1",
    single: "Unique", continue: "Continuer", repeatOne: "Répéter la sourate", repeatAll: "Répéter tout",
    noResults: "Aucun résultat pour \"%1\"", retry: "Réessayer",
    noAudio: "Aucun audio disponible pour ce récitant",
    reciterLoadFailed: "Impossible de charger les récitants",
    loadingReciters: "Chargement des récitants…",
    playbackFailed: "Échec de lecture. Réessayez ou passez en streaming.",
    downloaded: "Téléchargé", partial: "Partiel", notDownloaded: "Non téléchargé", inLibrary: "Dans la bibliothèque",
    tooltip: "Coran", nowPlaying: "Lecture en cours · %1",
    surahTabTitle: "Sourate", reciterTabTitle: "Récitant",
    verses: "%1 versets", seekHint: "Cliquer pour avancer",
    invalidInput: "Récitant ou sourate invalide",
    browse: "Parcourir", downloadingSurah: "Téléchargement de la sourate %1",
    clearCache: "Vider le cache", cacheSize: "Cache : %1", downloadFailed: "Échec du téléchargement", cacheClearFailed: "Cache indisponible", setupRequired: "Moteur audio absent — lancez install.sh dans le dossier du plugin",
    mpvMissing: "Lecture indisponible — mpv est-il installé ?",
    settings: "Paramètres", storage: "Stockage et Cache", clear: "Vider",
    downloadFolder: "Dossier de téléchargement", libraryFolder: "Dossier de bibliothèque locale",
    apply: "Appliquer", reset: "Réinitialiser",
    invalidPath: "Chemin invalide", pathNotWritable: "Dossier non inscriptible", libraryUnreadable: "Dossier non lisible",
    libraryHint: "Structure : <dossier>/<récitant>/<sourate>.mp3",
  },
  es: {
    tabSurah: "Sura", tabReciter: "Recitador",
    searchSurah: "Buscar sura (cualquier idioma)", searchReciter: "Buscar recitador",
    language: "Idioma", noSurahSelected: "Ninguna sura seleccionada",
    download: "Descargar", streamOnly: "Solo streaming", close: "Cerrar",
    downloadPrompt: "¿Descargar el mushaf completo (%1)?",
    downloadDesc: "~2 GB · 114 suras · reproducción sin conexión después. También puede transmitirse.",
    downloadRemaining: "Descargar las %1 suras restantes",
    downloading: "Descargando mushaf para %1",
    single: "Única", continue: "Continuar", repeatOne: "Repetir sura", repeatAll: "Repetir todo",
    noResults: "Sin resultados para \"%1\"", retry: "Reintentar",
    noAudio: "No hay audio disponible para este recitador",
    reciterLoadFailed: "No se pudieron cargar los recitadores",
    loadingReciters: "Cargando recitadores…",
    playbackFailed: "Error de reproducción. Reintenta o usa streaming.",
    downloaded: "Descargado", partial: "Parcial", notDownloaded: "No descargado", inLibrary: "En la biblioteca",
    tooltip: "Corán", nowPlaying: "Reproduciendo · %1",
    surahTabTitle: "Sura", reciterTabTitle: "Recitador",
    verses: "%1 versículos", seekHint: "Haz clic para buscar",
    invalidInput: "Recitador o sura no válidos",
    browse: "Explorar", downloadingSurah: "Descargando sura %1",
    clearCache: "Vaciar caché", cacheSize: "Caché: %1", downloadFailed: "Error de descarga", cacheClearFailed: "Caché no disponible", setupRequired: "Motor de audio ausente — ejecuta install.sh en la carpeta del plugin",
    mpvMissing: "Reproducción no disponible — ¿está instalado mpv?",
    settings: "Ajustes", storage: "Almacenamiento y Caché", clear: "Vaciar",
    downloadFolder: "Carpeta de descargas", libraryFolder: "Carpeta de biblioteca local",
    apply: "Aplicar", reset: "Restablecer",
    invalidPath: "Ruta no válida", pathNotWritable: "La carpeta no es escribible", libraryUnreadable: "La carpeta no es legible",
    libraryHint: "Estructura: <carpeta>/<recitador>/<sura>.mp3",
  },
  tr: {
    tabSurah: "Sure", tabReciter: "Okuyucu",
    searchSurah: "Sure ara (her dilde)", searchReciter: "Okuyucu ara",
    language: "Dil", noSurahSelected: "Sure seçilmedi",
    download: "İndir", streamOnly: "Sadece akış", close: "Kapat",
    downloadPrompt: "Tüm mushaf indirilsin mi (%1)?",
    downloadDesc: "~2 GB · 114 sure · sonrasında çevrimdışı çalar. Akış da yapabilirsiniz.",
    downloadRemaining: "Kalan %1 sureyi indir",
    downloading: "%1 için mushaf indiriliyor",
    single: "Tek", continue: "Devam et", repeatOne: "Sureyi tekrarla", repeatAll: "Tümünü tekrarla",
    noResults: "\"%1\" için sonuç yok", retry: "Yeniden dene",
    noAudio: "Bu okuyucu için ses yok",
    reciterLoadFailed: "Okuyucular yüklenemedi",
    loadingReciters: "Okuyucular yükleniyor…",
    playbackFailed: "Oynatma başarısız. Yeniden deneyin veya akış kullanın.",
    downloaded: "İndirildi", partial: "Kısmi", notDownloaded: "İndirilmedi", inLibrary: "Kitaplıkta",
    tooltip: "Kuran", nowPlaying: "Şu an çalıyor · %1",
    surahTabTitle: "Sure", reciterTabTitle: "Okuyucu",
    verses: "%1 ayet", seekHint: "Gitmek için tıklayın",
    invalidInput: "Geçersiz okuyucu veya sure",
    browse: "Gözat", downloadingSurah: "%1. sure indiriliyor",
    clearCache: "Önbelleği temizle", cacheSize: "Önbellek: %1", downloadFailed: "İndirme başarısız", cacheClearFailed: "Önbellek kullanılamıyor", setupRequired: "Ses motoru eksik — eklenti klasöründe install.sh çalıştırın",
    mpvMissing: "Oynatma kullanılamıyor — mpv yüklü mü?",
    settings: "Ayarlar", storage: "Depolama ve Önbellek", clear: "Temizle",
    downloadFolder: "İndirme klasörü", libraryFolder: "Yerel kitaplık klasörü",
    apply: "Uygula", reset: "Sıfırla",
    invalidPath: "Geçersiz yol", pathNotWritable: "Klasör yazılabilir değil", libraryUnreadable: "Klasör okunabilir değil",
    libraryHint: "Yapı: <klasör>/<okuyucu>/<sure>.mp3",
  },
  id: {
    tabSurah: "Surah", tabReciter: "Qari",
    searchSurah: "Cari surah (bahasa apa pun)", searchReciter: "Cari qari",
    language: "Bahasa", noSurahSelected: "Tidak ada surah dipilih",
    download: "Unduh", streamOnly: "Streaming saja", close: "Tutup",
    downloadPrompt: "Unduh mushaf lengkap (%1)?",
    downloadDesc: "~2 GB · 114 surah · bisa diputar offline setelahnya. Anda juga bisa streaming.",
    downloadRemaining: "Unduh %1 surah tersisa",
    downloading: "Mengunduh mushaf untuk %1",
    single: "Tunggal", continue: "Lanjutkan", repeatOne: "Ulangi surah", repeatAll: "Ulangi semua",
    noResults: "Tidak ada hasil untuk \"%1\"", retry: "Coba lagi",
    noAudio: "Tidak ada audio untuk qari ini",
    reciterLoadFailed: "Gagal memuat daftar qari",
    loadingReciters: "Memuat daftar qari…",
    playbackFailed: "Pemutaran gagal. Coba lagi atau gunakan streaming.",
    downloaded: "Terunduh", partial: "Sebagian", notDownloaded: "Belum diunduh", inLibrary: "Di pustaka",
    tooltip: "Al-Qur'an", nowPlaying: "Sedang diputar · %1",
    surahTabTitle: "Surah", reciterTabTitle: "Qari",
    verses: "%1 ayat", seekHint: "Klik untuk berpindah",
    invalidInput: "Qari atau surah tidak valid",
    browse: "Jelajahi", downloadingSurah: "Mengunduh surah %1",
    clearCache: "Bersihkan cache", cacheSize: "Cache: %1", downloadFailed: "Unduhan gagal", cacheClearFailed: "Cache tidak tersedia", setupRequired: "Mesin audio tidak ada — jalankan install.sh di folder plugin",
    mpvMissing: "Pemutaran tidak tersedia — apakah mpv terpasang?",
    settings: "Pengaturan", storage: "Penyimpanan & Cache", clear: "Bersihkan",
    downloadFolder: "Folder unduhan", libraryFolder: "Folder pustaka lokal",
    apply: "Terapkan", reset: "Atur ulang",
    invalidPath: "Jalur tidak valid", pathNotWritable: "Folder tidak dapat ditulis", libraryUnreadable: "Folder tidak dapat dibaca",
    libraryHint: "Struktur: <folder>/<qari>/<surah>.mp3",
  },
  ur: {
    tabSurah: "سورة", tabReciter: "قاری",
    searchSurah: "سورتہ تلاش کریں (کسی بھی زبان میں)", searchReciter: "قاری تلاش کریں",
    language: "زبان", noSurahSelected: "کوئی سورت منتخب نہیں",
    download: "ڈاؤن لوڈ", streamOnly: "صرف سٹریم", close: "بند کریں",
    downloadPrompt: "مکمل مصحف ڈاؤن لوڈ کریں (%1)؟",
    downloadDesc: "تقریباً 2 جی بی · 114 سورتیں · بعد ازاں آف لائن چلتی ہیں۔ سٹریم بھی کیا جا سکتا ہے۔",
    downloadRemaining: "بقیہ %1 سورتیں ڈاؤن لوڈ کریں",
    downloading: "%1 کا مصحف ڈاؤن لوڈ ہو رہا ہے",
    single: "واحد", continue: "جاری رکھیں", repeatOne: "سورت دہرائیں", repeatAll: "سب دہرائیں",
    noResults: "\"%1\" کے لیے کوئی نتیجہ نہیں", retry: "دوبارہ کوشش",
    noAudio: "اس قاری کے لیے آڈیو دستیاب نہیں",
    reciterLoadFailed: "قاریوں کی فہرست لوڈ نہیں ہو سکی",
    loadingReciters: "قاریوں کی فہرست لوڈ ہو رہی ہے…",
    playbackFailed: "پلے بیک ناکام۔ دوبارہ کوشش کریں یا سٹریم کریں۔",
    downloaded: "ڈاؤن لوڈ شدہ", partial: "جزوی", notDownloaded: "ڈاؤن لوڈ نہیں ہوا", inLibrary: "لائبریری میں",
    tooltip: "قرآن", nowPlaying: "چل رہا ہے · %1",
    surahTabTitle: "سورت", reciterTabTitle: "قاری",
    verses: "%1 آیات", seekHint: "جگہ کے لیے کلک کریں",
    invalidInput: "غیر درست قاری یا سورت",
    browse: "براؤز کریں", downloadingSurah: "سورت %1 ڈاؤن لوڈ ہو رہی ہے",
    clearCache: "کیشے صاف کریں", cacheSize: "کیشے: %1", downloadFailed: "ڈاؤن لوڈ ناکام", cacheClearFailed: "کیشے دستیاب نہیں", setupRequired: "آڈیو انجن موجود نہیں — پلگ ان فولڈر میں install.sh چلائیں",
    mpvMissing: "پلے بیک دستیاب نہیں — کیا mpv نصب ہے؟",
    settings: "سیٹنگز", storage: "سٹوریج اور کیشے", clear: "صاف کریں",
    downloadFolder: "ڈاؤن لوڈ فولڈر", libraryFolder: "مقامی لائبریری فولڈر",
    apply: "لاگو کریں", reset: "ری سیٹ",
    invalidPath: "غلط راستہ", pathNotWritable: "فولڈر لکھنے کے قابل نہیں", libraryUnreadable: "فولڈر پڑھنے کے قابل نہیں",
    libraryHint: "ترتیب: <فولڈر>/<قاری>/<سورت>.mp3",
  },
  bn: {
    tabSurah: "সূরা", tabReciter: "ক্বারী",
    searchSurah: "সূরা খুঁজুন (যেকোনো ভাষায়)", searchReciter: "ক্বারী খুঁজুন",
    language: "ভাষা", noSurahSelected: "কোনো সূরা নির্বাচিত নেই",
    download: "ডাউনলোড", streamOnly: "শুধু স্ট্রিম", close: "বন্ধ",
    downloadPrompt: "সম্পূর্ণ মুসহাফ ডাউনলোড করবেন (%1)?",
    downloadDesc: "~২ জিবি · ১১৪ সূরা · পরে অফলাইনে চলে। স্ট্রিমও করতে পারবেন।",
    downloadRemaining: "অবশিষ্ট %1 সূরা ডাউনলোড করুন",
    downloading: "%1-এর জন্য মুসহাফ ডাউনলোড হচ্ছে",
    single: "একটি", continue: "চালিয়ে যান", repeatOne: "সূরা পুনরাবৃত্তি", repeatAll: "সব পুনরাবৃত্তি",
    noResults: "\"%1\" এর জন্য কোনো ফলাফল নেই", retry: "আবার চেষ্টা",
    noAudio: "এই ক্বারীর জন্য অডিও নেই",
    reciterLoadFailed: "ক্বারীদের তালিকা লোড করা যায়নি",
    loadingReciters: "ক্বারীদের তালিকা লোড হচ্ছে…",
    playbackFailed: "প্লেব্যাক ব্যর্থ। আবার চেষ্টা করুন বা স্ট্রিম করুন।",
    downloaded: "ডাউনলোড হয়েছে", partial: "আংশিক", notDownloaded: "ডাউনলোড হয়নি", inLibrary: "লাইব্রেরিতে",
    tooltip: "কুরআন", nowPlaying: "চলছে · %1",
    surahTabTitle: "সূরা", reciterTabTitle: "ক্বারী",
    verses: "%1 আয়াত", seekHint: "যেতে ক্লিক করুন",
    invalidInput: "অবৈধ ক্বারী বা সূরা",
    browse: "ব্রাউজ করুন", downloadingSurah: "সূরা %1 ডাউনলোড হচ্ছে",
    clearCache: "ক্যাশ মুছুন", cacheSize: "ক্যাশ: %1", downloadFailed: "ডাউনলোড ব্যর্থ", cacheClearFailed: "ক্যাশ উপলব্ধ নেই", setupRequired: "অডিও ইঞ্জিন অনুপস্থিত — প্লাগইন ফোল্ডারে install.sh চালান",
    mpvMissing: "প্লেব্যাক পাওয়া যাচ্ছে না — mpv কি ইনস্টল আছে?",
    settings: "সেটিংস", storage: "স্টোরেজ ও ক্যাশ", clear: "মুছুন",
    downloadFolder: "ডাউনলোড ফোল্ডার", libraryFolder: "স্থানীয় লাইব্রেরি ফোল্ডার",
    apply: "প্রয়োগ", reset: "রিসেট",
    invalidPath: "অবৈধ পথ", pathNotWritable: "ফোল্ডারে লেখা যায় না", libraryUnreadable: "ফোল্ডার পড়া যায় না",
    libraryHint: "কাঠামো: <ফোল্ডার>/<ক্বারী>/<সূরা>.mp3",
  },
  ru: {
    tabSurah: "Сура", tabReciter: "Чтец",
    searchSurah: "Поиск суры (на любом языке)", searchReciter: "Поиск чтеца",
    language: "Язык", noSurahSelected: "Сура не выбрана",
    download: "Скачать", streamOnly: "Только стриминг", close: "Закрыть",
    downloadPrompt: "Скачать полный мусхаф (%1)?",
    downloadDesc: "~2 ГБ · 114 сур · затем воспроизведение офлайн. Можно и стримить.",
    downloadRemaining: "Скачать оставшиеся %1 сур",
    downloading: "Скачивание мусхафа для %1",
    single: "Одна", continue: "Продолжить", repeatOne: "Повтор суры", repeatAll: "Повторять всё",
    noResults: "Нет результатов для \"%1\"", retry: "Повторить",
    noAudio: "Для этого чтеца аудио недоступно",
    reciterLoadFailed: "Не удалось загрузить чтецов",
    loadingReciters: "Загрузка чтецов…",
    playbackFailed: "Ошибка воспроизведения. Повторите или включите стриминг.",
    downloaded: "Скачано", partial: "Частично", notDownloaded: "Не скачано", inLibrary: "В библиотеке",
    tooltip: "Коран", nowPlaying: "Сейчас играет · %1",
    surahTabTitle: "Сура", reciterTabTitle: "Чтец",
    verses: "%1 аятов", seekHint: "Нажмите для перемотки",
    invalidInput: "Неверный чтец или сура",
    browse: "Обзор", downloadingSurah: "Скачивание суры %1",
    clearCache: "Очистить кэш", cacheSize: "Кэш: %1", downloadFailed: "Ошибка загрузки", cacheClearFailed: "Кэш недоступен", setupRequired: "Аудио-движок отсутствует — запустите install.sh в папке плагина",
    mpvMissing: "Воспроизведение недоступно — установлен ли mpv?",
    settings: "Настройки", storage: "Память и Кэш", clear: "Очистить",
    downloadFolder: "Папка загрузок", libraryFolder: "Папка локальной библиотеки",
    apply: "Применить", reset: "Сбросить",
    invalidPath: "Неверный путь", pathNotWritable: "Папка недоступна для записи", libraryUnreadable: "Папка недоступна для чтения",
    libraryHint: "Структура: <папка>/<чтец>/<сура>.mp3",
  },
  zh: {
    tabSurah: "章节", tabReciter: "诵读者",
    searchSurah: "搜索章节（任何语言）", searchReciter: "搜索诵读者",
    language: "语言", noSurahSelected: "未选择章节",
    download: "下载", streamOnly: "仅流播放", close: "关闭",
    downloadPrompt: "下载完整誊本（%1）？",
    downloadDesc: "约 2 GB · 114 章 · 之后可离线播放。也可选择流播放。",
    downloadRemaining: "下载剩余 %1 章",
    downloading: "正在为 %1 下载誊本",
    single: "单章", continue: "继续", repeatOne: "重复本章", repeatAll: "全部重复",
    noResults: "没有“%1”的结果", retry: "重试",
    noAudio: "该诵读者没有可用音频",
    reciterLoadFailed: "无法加载诵读者列表",
    loadingReciters: "正在加载诵读者列表…",
    playbackFailed: "播放失败。请重试或改用流播放。",
    downloaded: "已下载", partial: "部分", notDownloaded: "未下载", inLibrary: "在曲库中",
    tooltip: "古兰经", nowPlaying: "正在播放 · %1",
    surahTabTitle: "章节", reciterTabTitle: "诵读者",
    verses: "%1 节经文", seekHint: "点击跳转",
    invalidInput: "诵读者或章节无效",
    browse: "浏览", downloadingSurah: "正在下载章节 %1",
    clearCache: "清除缓存", cacheSize: "缓存：%1", downloadFailed: "下载失败", cacheClearFailed: "缓存不可用", setupRequired: "缺少音频引擎 — 请在插件目录中运行 install.sh",
    mpvMissing: "播放不可用 — 是否已安装 mpv？",
    settings: "设置", storage: "存储与缓存", clear: "清除",
    downloadFolder: "下载文件夹", libraryFolder: "本地曲库文件夹",
    apply: "应用", reset: "重置",
    invalidPath: "路径无效", pathNotWritable: "文件夹不可写", libraryUnreadable: "文件夹不可读",
    libraryHint: "结构：<文件夹>/<诵读家>/<章节>.mp3",
  }
}

function tr(lang, key) {
  var table = STRINGS[lang] || STRINGS["en"] || {}
  var s = table[key]
  if (s === undefined && STRINGS["en"]) s = STRINGS["en"][key]
  return (s === undefined) ? key : String(s)
}

function trArgs(lang, key, args) {
  var s = tr(lang, key)
  for (var i = 0; i < args.length; i++) s = s.replace("%" + (i + 1), String(args[i]))
  return s
}

// --- parsing -------------------------------------------------------------

function pad3(n) {
  var s = String(n)
  while (s.length < 3) s = "0" + s
  return s
}

function parseReciters(json, jsonAr) {
  if (!json) return []
  var data = Array.isArray(json) ? json : (json.reciters || json.data || [])

  // If data comes from mp3quran API
  if (data.length > 0 && data[0].moshaf !== undefined) {
    var arMap = {}
    if (jsonAr && jsonAr.reciters) {
      for (var j = 0; j < jsonAr.reciters.length; j++) {
        var itemAr = jsonAr.reciters[j]
        if (itemAr && itemAr.id) arMap[itemAr.id] = itemAr.name
      }
    }
    var outMp3 = []
    for (var i = 0; i < data.length; i++) {
      if (outMp3.length >= 1000) break
      var r = data[i]
      if (!r || !r.moshaf || !Array.isArray(r.moshaf) || r.moshaf.length === 0) continue
      var m = null
      for (var k = 0; k < r.moshaf.length; k++) {
        var itemM = r.moshaf[k]
        if (itemM.rewaya_id === 1 || (itemM.name && itemM.name.indexOf("Hafs") !== -1)) {
          m = itemM
          break
        }
      }
      if (!m) m = r.moshaf[0]
      if (!m) continue
      var server = sanitizeServer(m.server)
      if (server === "") continue

      var identifier = "mp3quran_" + r.id
      if (r.id === 123 || (r.name && r.name.indexOf("Mishary Alafasi") !== -1)) identifier = "ar.alafasy"
      if (!isSafeIdentifier(identifier)) continue
      // Field limits: a hostile catalog must not be able to smuggle huge
      // strings into the UI or persisted state.
      if (String(r.name || "").length > 200 || String(r.englishName || "").length > 200) continue
      if ((arMap[r.id] || "").length > 200) continue

      outMp3.push({
        identifier: identifier,
        id: String(r.id),
        name: arMap[r.id] || String(r.name || ""),
        englishName: String(r.name || ""),
        server: server
      })
    }
    outMp3.sort(function(a, b) {
      var key = a.englishName || a.name
      var other = b.englishName || b.name
      return key.localeCompare(other)
    })
    return outMp3
  }

  // Legacy / fallback parsing
  var out = []
  for (var idx = 0; idx < data.length; idx++) {
    if (out.length >= 1000) break
    var rec = data[idx]
    if (!rec || !rec.identifier) continue
    var identifier = String(rec.identifier)
    if (!isSafeIdentifier(identifier)) continue
    var levels = rec.audioLevels || []
    if (levels.indexOf("surah") === -1) continue
    if (String(rec.name || "").length > 200 || String(rec.englishName || "").length > 200) continue
    out.push({
      identifier: identifier,
      name: String(rec.name || ""),
      englishName: String(rec.englishName || ""),
      levels: levels
    })
  }
  out.sort(function(a, b) {
    var key = a.englishName || a.name
    var other = b.englishName || b.name
    return key.localeCompare(other)
  })
  return out
}

function parseSurahs(json) {
  if (!json) return []
  var out = []
  for (var i = 0; i < json.length; i++) {
    var s = json[i]
    if (!s || !s.number) continue
    out.push({
      number: Number(s.number),
      name: String(s.name || ""),
      transliteration: String(s.transliteration || ""),
      type: String(s.type || ""),
      totalVerses: Number(s.total_verses || 0),
      translations: s.translations || {}
    })
  }
  return out
}

// --- validation ------------------------------------------------------------

function isValidSurahNumber(n) {
  return typeof n === "number" && n >= 1 && n <= 114 && Math.floor(n) === n
}

function reciterExists(reciters, id) {
  if (!reciters || !id) return false
  for (var i = 0; i < reciters.length; i++) {
    if (reciters[i].identifier === id) return true
  }
  return false
}

function isValidLanguage(code) {
  if (!code) return false
  for (var i = 0; i < LANGUAGES.length; i++) {
    if (LANGUAGES[i].value === code) return true
  }
  return false
}

// --- naming --------------------------------------------------------------
// Pure chosen-language labels: NO Arabic is appended for non-Arabic languages.

function surahLabel(surah, language) {
  if (!surah) return ""
  if (language === "ar") return surah.name
  if (language === "en") return surah.transliteration
  var t = surah.translations ? surah.translations[language] : ""
  return t || surah.transliteration
}

function surahDisplayLabel(surah, language) {
  return surahLabel(surah, language)
}

function surahListLabel(surah, language) {
  var label = surahLabel(surah, language)
  if (language === "ar") return label
  var arabic = surah.name || ""
  return arabic ? label + "  " + arabic : label
}


function reciterLabel(reciter, language) {
  if (!reciter) return ""
  if (language === "ar") return reciter.name
  return reciter.englishName || reciter.name
}

function reciterDisplayLabel(reciter, language) {
  return reciterLabel(reciter, language)
}

// --- filtering ------------------------------------------------------------

function surahMatches(surah, query) {
  if (!query) return true
  var q = query.toLowerCase()
  var fields = [surah.transliteration, surah.name]
  var tr_ = surah.translations || {}
  for (var i = 0; i < LANGUAGES.length; i++) {
    fields.push(tr_[LANGUAGES[i].value] || "")
  }
  for (var j = 0; j < fields.length; j++) {
    if (fields[j] && fields[j].toLowerCase().indexOf(q) !== -1) return true
  }
  return false
}

function reciterMatches(reciter, query) {
  if (!query) return true
  var q = query.toLowerCase()
  return (reciter.name && reciter.name.toLowerCase().indexOf(q) !== -1)
    || (reciter.englishName && reciter.englishName.toLowerCase().indexOf(q) !== -1)
}

function filterSurahs(surahs, query) {
  var out = []
  for (var i = 0; i < surahs.length; i++) {
    if (surahMatches(surahs[i], query)) out.push(surahs[i])
  }
  return out
}

function filterReciters(reciters, query) {
  var out = []
  for (var i = 0; i < reciters.length; i++) {
    if (reciterMatches(reciters[i], query)) out.push(reciters[i])
  }
  return out
}

// --- URL safety (catalog SSRF hardening) ----------------------------------
// Catalog `server` values are untrusted. Before a URL is given to curl or mpv
// it must be https, on an allowlisted audio CDN, with a public host (no
// loopback/private/link-local/ULA, no IPv4-mapped IPv6, no userinfo/query/
// fragment). Identifiers used as path segments are similarly restricted.

var SAFE_IDENTIFIER_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
var ALLOWED_AUDIO_HOST_SUFFIXES = ["mp3quran.net", "islamic.app"]

function isSafeIdentifier(id) {
  if (typeof id !== "string" || id.length === 0 || id.length > 64) return false
  if (!SAFE_IDENTIFIER_RE.test(id)) return false
  if (id === "." || id === "..") return false
  return true
}

function _stripTrailingDots(host) {
  var h = String(host)
  while (h.length > 0 && h.charAt(h.length - 1) === ".") h = h.substring(0, h.length - 1)
  return h
}

function _parseIpv4(host) {
  var h = _stripTrailingDots(host)
  var parts = h.split(".")
  if (parts.length < 2 || parts.length > 4) return null
  var nums = []
  for (var i = 0; i < parts.length; i++) {
    // Decimal octets only. Hex/octal encodings (0x7f, 0177) are rejected.
    if (!/^[0-9]+$/.test(parts[i])) return null
    if (parts[i].length > 1 && parts[i].charAt(0) === "0") return null
    var n = parseInt(parts[i], 10)
    if (isNaN(n) || n < 0 || n > 255) return null
    nums.push(n)
  }
  while (nums.length < 4) nums.splice(nums.length - 1, 0, 0)
  return nums
}

function _looksLikeIpv4(host) {
  var h = _stripTrailingDots(host)
  var parts = h.split(".")
  if (parts.length < 2 || parts.length > 4) return false
  for (var i = 0; i < parts.length; i++) {
    if (!/^(0x[0-9a-f]+|0[0-7]*|[0-9]+)$/i.test(parts[i])) return false
  }
  return true
}

function _isBlockedIpv4(parts) {
  if (!parts || parts.length !== 4) return true
  var a = parts[0], b = parts[1], c = parts[2]
  if (a === 0 || a === 10 || a === 127) return true
  if (a === 169 && b === 254) return true           // link-local
  if (a === 172 && b >= 16 && b <= 31) return true  // private
  if (a === 192 && b === 168) return true           // private
  if (a === 100 && b >= 64 && b <= 127) return true // CGNAT
  if (a >= 224 && a <= 255) return true             // multicast + reserved 240/4
  if (a === 192 && b === 0 && c === 0) return true  // 192.0.0.0/24
  if (a === 192 && b === 0 && c === 2) return true  // TEST-NET-1 (192.0.2.0/24)
  if (a === 198 && b === 51 && c === 100) return true  // TEST-NET-2 (198.51.100.0/24)
  if (a === 203 && b === 0 && c === 113) return true   // TEST-NET-3 (203.0.113.0/24)
  return false
}

function isAllowedAudioHost(host) {
  if (!host) return false
  var h = _stripTrailingDots(String(host).toLowerCase())
  for (var i = 0; i < ALLOWED_AUDIO_HOST_SUFFIXES.length; i++) {
    var s = ALLOWED_AUDIO_HOST_SUFFIXES[i]
    if (h === s) return true
    if (h.length > s.length + 1 && h.substring(h.length - s.length - 1) === "." + s) return true
  }
  return false
}

// isBlockedHost(host) — true for loopback/private/link-local/ULA addresses and
// clearly-internal hostnames (localhost, *.local, *.internal, *.localhost,
// single-label). IPv4-mapped IPv6 and short/hex/octal IPv4 forms are blocked.
function isBlockedHost(host) {
  if (!host) return true
  var h = _stripTrailingDots(String(host).toLowerCase())
  if (!h) return true
  if (h === "localhost" || h === "local") return true
  if (h.length > 10 && h.substring(h.length - 10) === ".localhost") return true
  if (h.indexOf(".local") !== -1 || h.indexOf(".internal") !== -1) return true
  if (h.indexOf(":") !== -1) {
    if (h === "::" || h === "::1" || h === "0:0:0:0:0:0:0:1" || h === "0:0:0:0:0:0:0:0") return true
    // IPv4-mapped / IPv4-compatible (e.g. ::ffff:127.0.0.1, ::ffff:7f00:1)
    if (h.indexOf("ffff:") !== -1 || h.indexOf(":ffff") !== -1) return true
    if (/:\d+\.\d+\.\d+\.\d+$/.test(h)) return true
    if (h.indexOf("fe8") === 0 || h.indexOf("fe9") === 0
        || h.indexOf("fea") === 0 || h.indexOf("feb") === 0
        || h.indexOf("fec") === 0 || h.indexOf("fc") === 0
        || h.indexOf("fd") === 0) return true
    return false
  }
  if (h.indexOf(".") === -1) return true
  if (_looksLikeIpv4(h)) {
    var parts = _parseIpv4(h)
    if (!parts) return true
    return _isBlockedIpv4(parts)
  }
  return false
}

// _isValidPort(p) — strict port: non-empty, decimal digits only, no leading
// zeros, 1..65535.
function _isValidPort(p) {
  if (typeof p !== "string" || p.length === 0) return false
  if (!/^[0-9]+$/.test(p)) return false
  if (p.length > 1 && p.charAt(0) === "0") return false
  var n = parseInt(p, 10)
  return !isNaN(n) && n >= 1 && n <= 65535
}

// isSafeServerPrefix(value) — true for an absolute https URL on an
// allowlisted audio CDN, no userinfo, no query, no fragment, no control chars,
// no encoded delimiters, valid port, safe host.
function isSafeServerPrefix(value) {
  if (typeof value !== "string") return false
  var url = value.trim()
  if (url.length === 0 || url.length > 512) return false
  if (/[\x00-\x20\x7f]/.test(url)) return false
  // Encoded delimiters (%2e %2f %3f %23 %40 %5c, case-insensitive) can be used
  // to smuggle path/userinfo/query structure past naive URL checks.
  if (/%(?:2e|2f|3f|23|40|5c)/i.test(url)) return false
  var m = url.match(/^(https):\/\/([^/?#]+)/)
  if (!m) return false
  if (url.indexOf("#") !== -1 || url.indexOf("?") !== -1) return false
  var authority = m[2]
  if (authority.indexOf("@") !== -1) return false
  var host = authority
  if (host.charAt(0) === "[") {
    // Bracketed IPv6: inner literal must be hex/colon-only, contain >= 1
    // colon, and carry no zone id. Anything after the bracket must be a port.
    var close = authority.indexOf("]")
    if (close === -1) return false
    var inner = authority.substring(1, close)
    if (!/^[0-9a-fA-F:]+$/.test(inner)) return false
    if (inner.indexOf(":") === -1) return false
    if (inner.indexOf("%") !== -1) return false
    host = inner
    var after = authority.substring(close + 1)
    if (after !== "") {
      if (after.charAt(0) !== ":") return false
      if (!_isValidPort(after.substring(1))) return false
    }
  } else {
    var lastColon = host.lastIndexOf(":")
    if (lastColon !== -1) {
      if (!_isValidPort(host.substring(lastColon + 1))) return false
      host = host.substring(0, lastColon)
    }
  }
  if (!/^[A-Za-z0-9.:-]+$/.test(host) && host.indexOf(":") === -1) return false
  if (isBlockedHost(host)) return false
  return isAllowedAudioHost(host)
}

// sanitizeServer(value) — validated server prefix with a trailing slash, or "".
function sanitizeServer(value) {
  if (!isSafeServerPrefix(value)) return ""
  var url = String(value).trim()
  if (url.charAt(url.length - 1) !== "/") url += "/"
  return url
}

// isSafeRemoteUrl(url) — final-url guard applied after URL construction.
function isSafeRemoteUrl(url) {
  return isSafeServerPrefix(url)
}

// isSafeReciter(reciter) — server prefix and identifier are both safe.
function isSafeReciter(reciter) {
  if (!reciter) return false
  if (!isSafeIdentifier(reciter.identifier)) return false
  if (reciter.server !== undefined && reciter.server !== null) {
    if (sanitizeServer(reciter.server) === "") return false
  }
  return true
}

// --- IPC / CLI argument parsers (strict; used by QML IPC and quranctl
// companion logic). These never throw and never accept junk like "1junk".

// isSafeReciterArg(id) — a reciter id usable as a path segment: alnum first,
// letters/digits/dot/dash/underscore only, <= 64 chars. No "/" is possible,
// so no traversal even with "." allowed mid-string.
function isSafeReciterArg(id) {
  return isSafeIdentifier(id)
}

// parseSurahArg(str) — strict decimal 1..114 (no leading zeros), or null.
function parseSurahArg(str) {
  if (typeof str !== "string") return null
  if (!/^[0-9]+$/.test(str)) return null
  if (str.length > 1 && str.charAt(0) === "0") return null
  var n = parseInt(str, 10)
  if (isNaN(n) || n < 1 || n > 114) return null
  return n
}

// parseSeekArg(str) — strict optional-sign decimal, or null.
function parseSeekArg(str) {
  if (typeof str !== "string") return null
  if (!/^-?[0-9]+$/.test(str)) return null
  var v = parseInt(str, 10)
  return isNaN(v) ? null : v
}

// --- fetch cooldown (per reciter:surah) ------------------------------------
// After a failed fetch (or a forced playback error on a cached file), further
// fetches for the same key are refused for COOLDOWN_MS. A caller cannot force
// more than one real network fetch per reciter:surah inside the window, even
// via repeated IPC or forced playback errors. Pure functions over a plain map
// so the gate logic is independently testable; Service.qml owns the map.

var COOLDOWN_MS = 10000

function cooldownActive(map, key, now) {
  if (!map || typeof key !== "string") return true
  var until = map[key]
  return typeof until === "number" && now < until
}

function markCooldown(map, key, now) {
  if (!map || typeof key !== "string") return
  map[key] = now + COOLDOWN_MS
}

function clearCooldown(map, key) {
  if (map && typeof key === "string") delete map[key]
}

// --- audio ----------------------------------------------------------------

function audioUrl(reciterId, surahNumber, reciterObj) {
  var n = Number(surahNumber)
  if (!isValidSurahNumber(n)) return ""
  if (reciterObj && reciterObj.server) {
    var url = sanitizeServer(reciterObj.server)
    if (url === "") return ""
    url = url + pad3(n) + ".mp3"
    return isSafeRemoteUrl(url) ? url : ""
  }
  var providerId = reciterId === "ar.ajamy" ? "ar.ahmedajamy" : reciterId
  if (!isSafeIdentifier(providerId)) return ""
  var url = CDN_BASE + "/" + providerId + "/" + n + ".mp3"
  // Run the constructed default-CDN URL through the same final-url guard as
  // server-based URLs, for consistency.
  return isSafeRemoteUrl(url) ? url : ""
}

function localAudioUrl(dataDir, reciterId, surahNumber) {
  if (typeof dataDir !== "string" || dataDir.indexOf("..") !== -1) return ""
  if (!isSafeIdentifier(reciterId) || !isValidSurahNumber(Number(surahNumber))) return ""
  return "file://" + dataDir + "/" + reciterId + "/" + Number(surahNumber) + ".mp3"
}

// --- configurable storage roots ---------------------------------------------

// sanitizeDirPath(p, home) — validate a user-configured directory (download
// root or library root). Expands a leading "~/", requires an absolute result,
// and rejects traversal components and control characters anywhere in the
// input (same rules as quranctl's --dest-root). Returns the cleaned path, or
// "" when the input is unusable. An empty input means "back to default".
function sanitizeDirPath(p, home) {
  p = String(p === undefined || p === null ? "" : p).trim()
  if (p === "") return ""
  if (p.indexOf("~/") === 0) {
    home = String(home || "")
    if (home === "" || home.charAt(0) !== "/") return ""
    p = home + p.substring(1)
  }
  if (p.length === 0 || p.charAt(0) !== "/") return ""
  for (var i = 0; i < p.length; i++) {
    var c = p.charCodeAt(i)
    if (c < 32 || c === 127) return ""
  }
  var parts = p.split("/")
  for (var j = 0; j < parts.length; j++) {
    if (parts[j] === "..") return ""
  }
  // Collapse duplicate slashes and any trailing slash (root "/" stays "/").
  var out = []
  for (var k = 0; k < parts.length; k++) {
    if (parts[k] !== "" || out.length === 0) out.push(parts[k])
  }
  while (out.length > 1 && out[out.length - 1] === "") out.pop()
  return out.join("/")
}

// pushLegacyRoot(roots, previous, current) — remember a previously-used
// download root so its already-downloaded files stay resolvable after the
// user changes the folder. Deduped, never equal to the current root, capped.
var MAX_LEGACY_ROOTS = 8

function pushLegacyRoot(roots, previous, current) {
  var out = Array.isArray(roots) ? roots.slice() : []
  previous = String(previous || "")
  current = String(current || "")
  if (previous === "" || !Array.isArray(out)) return out
  if (previous === current) return out
  var idx = out.indexOf(previous)
  if (idx !== -1) out.splice(idx, 1)
  // Switching back to a remembered root must drop it from history.
  idx = out.indexOf(current)
  if (idx !== -1) out.splice(idx, 1)
  out.push(previous)
  while (out.length > MAX_LEGACY_ROOTS) out.shift()
  return out
}

// mergeLegacyRoots(raw, currentRoot) — sanitize a persisted legacy-roots
// array on load: valid paths only, deduped, current root dropped, capped.
function mergeLegacyRoots(raw, currentRoot, home) {
  var out = []
  if (!Array.isArray(raw)) return out
  for (var i = 0; i < raw.length && out.length < MAX_LEGACY_ROOTS; i++) {
    var clean = sanitizeDirPath(raw[i], home)
    if (clean === "" || clean === currentRoot) continue
    if (out.indexOf(clean) !== -1) continue
    out.push(clean)
  }
  return out
}

// --- format helpers --------------------------------------------------------

function formatTime(ms) {
  if (!ms || ms < 0) ms = 0
  var total = Math.floor(ms / 1000)
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
  return m + ":" + (s < 10 ? "0" : "") + s
}

function formatSize(bytes) {
  if (!bytes || bytes < 0) bytes = 0
  if (bytes < 1024) return bytes + " B"
  var kb = bytes / 1024
  if (kb < 1024) return (kb >= 100 ? Math.round(kb) : Math.round(kb * 10) / 10) + " KB"
  var mb = kb / 1024
  if (mb < 1024) return (mb >= 100 ? Math.round(mb) : Math.round(mb * 10) / 10) + " MB"
  var gb = mb / 1024
  return (gb >= 100 ? Math.round(gb) : Math.round(gb * 10) / 10) + " GB"
}

function slugify(str) {
  return String(str || "").replace(/[^a-z0-9]/gi, "").toLowerCase()
}

function modeLabel(language, mode) {
  switch (mode) {
    case MODE_SINGLE: return tr(language, "single")
    case MODE_CONTINUE: return tr(language, "continue")
    case MODE_REPEAT_ONE: return tr(language, "repeatOne")
    case MODE_REPEAT_ALL: return tr(language, "repeatAll")
  }
  return tr(language, "single")
}
