//! Languages, keyboards and time zones: which the computer uses
//! (`Settings`, kept in /data/system/locale and chosen in setup and
//! Settings), and what they mean for the apps: the keys' characters
//! (`Keyboard.char`), local time (`TimeZone`), how dates, times and
//! temperatures are written, and the words that differ between languages
//! (`text`).
//!
//! Dazzle's text is written in British English; a language that writes
//! something differently says so in its table (see `text`).
//!
//!     locale.current = locale.load().language;
//!     const label = locale.text("16-bit colour");

const std = @import("std");
const linux = std.os.linux;
pub const timezone = @import("timezone.zig");
pub const TimeZone = timezone.TimeZone;

pub const Language = enum {
    en_us,
    en_gb,
    en_au,
    en_nz,
    en_ca,
    es_es,
    es_mx,
    es_ar,
    es_co,
    es_cl,
    es_pe,
    es_us,
    zh_cn,
    fr_fr,
    fr_ca,
    de_de,
    pt_br,
    pt_pt,
    ja_jp,
    ar_eg,

    /// Its code, as BCP 47 writes it: "en-GB".
    pub fn code(l: Language) []const u8 {
        return switch (l) {
            .en_us => "en-US",
            .en_gb => "en-GB",
            .en_au => "en-AU",
            .en_nz => "en-NZ",
            .en_ca => "en-CA",
            .es_es => "es-ES",
            .es_mx => "es-MX",
            .es_ar => "es-AR",
            .es_co => "es-CO",
            .es_cl => "es-CL",
            .es_pe => "es-PE",
            .es_us => "es-US",
            .zh_cn => "zh-CN",
            .fr_fr => "fr-FR",
            .fr_ca => "fr-CA",
            .de_de => "de-DE",
            .pt_br => "pt-BR",
            .pt_pt => "pt-PT",
            .ja_jp => "ja-JP",
            .ar_eg => "ar-EG",
        };
    }

    /// The language it is a kind of (for its words and ways).
    pub fn family(l: Language) Family {
        return switch (l) {
            .en_us, .en_gb, .en_au, .en_nz, .en_ca => .english,
            .es_es, .es_mx, .es_ar, .es_co, .es_cl, .es_pe, .es_us => .spanish,
            .zh_cn => .chinese,
            .fr_fr, .fr_ca => .french,
            .de_de => .german,
            .pt_br, .pt_pt => .portuguese,
            .ja_jp => .japanese,
            .ar_eg => .arabic,
        };
    }

    /// Written right to left (and its interface laid out so).
    pub fn rightToLeft(l: Language) bool {
        return l.family() == .arabic;
    }

    /// Spanish (of any country).
    pub fn spanish(l: Language) bool {
        return l.family() == .spanish;
    }

    pub fn fromCode(text_: []const u8) ?Language {
        for (std.enums.values(Language)) |l| if (std.ascii.eqlIgnoreCase(l.code(), text_)) return l;
        return null;
    }

    /// Its name, in itself.
    pub fn name(l: Language) []const u8 {
        return switch (l) {
            .en_us => "English (United States)",
            .en_gb => "English (United Kingdom)",
            .en_au => "English (Australia)",
            .en_nz => "English (New Zealand)",
            .en_ca => "English (Canada)",
            .es_es => "Español (España)",
            .es_mx => "Español (México)",
            .es_ar => "Español (Argentina)",
            .es_co => "Español (Colombia)",
            .es_cl => "Español (Chile)",
            .es_pe => "Español (Perú)",
            .es_us => "Español (Estados Unidos)",
            .zh_cn => "中文（简体）",
            .fr_fr => "Français (France)",
            .fr_ca => "Français (Canada)",
            .de_de => "Deutsch (Deutschland)",
            .pt_br => "Português (Brasil)",
            .pt_pt => "Português (Portugal)",
            .ja_jp => "日本語",
            .ar_eg => "العربية (مصر)",
        };
    }

    /// "Hello" in it (setup's first page greets in every language).
    pub fn hello(l: Language) []const u8 {
        return switch (l.family()) {
            .english => "Hello",
            .spanish => "Hola",
            .chinese => "你好",
            .french => "Bonjour",
            .german => "Hallo",
            .portuguese => "Olá",
            .japanese => "こんにちは",
            .arabic => "مرحبا",
        };
    }

    /// Every language, the most spoken first: languages by how many speak
    /// them (English, Chinese, Spanish, Arabic, French, Portuguese, German,
    /// Japanese), and each one's places by how many speak it there.
    pub const by_speakers = [_]Language{
        .en_us, .en_gb, .en_ca, .en_au, .en_nz,
        .zh_cn,
        .es_mx, .es_co, .es_es, .es_ar, .es_us, .es_pe, .es_cl,
        .ar_eg,
        .fr_fr, .fr_ca,
        .pt_br, .pt_pt,
        .de_de,
        .ja_jp,
    };

    /// Its name in English, for finding it by ("Spanish (Mexico)").
    pub fn englishName(l: Language) []const u8 {
        return switch (l) {
            .es_es => "Spanish (Spain)",
            .es_mx => "Spanish (Mexico)",
            .es_ar => "Spanish (Argentina)",
            .es_co => "Spanish (Colombia)",
            .es_cl => "Spanish (Chile)",
            .es_pe => "Spanish (Peru)",
            .es_us => "Spanish (United States)",
            .zh_cn => "Chinese (Simplified)",
            .fr_fr => "French (France)",
            .fr_ca => "French (Canada)",
            .de_de => "German (Germany)",
            .pt_br => "Portuguese (Brazil)",
            .pt_pt => "Portuguese (Portugal)",
            .ja_jp => "Japanese",
            .ar_eg => "Arabic (Egypt)",
            else => l.name(),
        };
    }

    /// The time zone most people there are in (or, in a country of
    /// several, its capital's), to start with.
    pub fn timeZone(l: Language) TimeZone {
        return TimeZone.fromName(switch (l) {
            .en_us => "America/New_York",
            .en_gb => "Europe/London",
            .en_au => "Australia/Sydney",
            .en_nz => "Pacific/Auckland",
            .en_ca => "America/Toronto",
            .es_es => "Europe/Madrid",
            .es_mx => "America/Mexico_City",
            .es_ar => "America/Argentina/Buenos_Aires",
            .es_co => "America/Bogota",
            .es_cl => "America/Santiago",
            .es_pe => "America/Lima",
            .es_us => "America/New_York",
            .zh_cn => "Asia/Shanghai",
            .fr_fr => "Europe/Paris",
            .fr_ca => "America/Toronto",
            .de_de => "Europe/Berlin",
            .pt_br => "America/Sao_Paulo",
            .pt_pt => "Europe/Lisbon",
            .ja_jp => "Asia/Tokyo",
            .ar_eg => "Africa/Cairo",
        }) orelse .utc;
    }

    /// The keyboard most people there have.
    pub fn keyboard(l: Language) Keyboard {
        return switch (l) {
            .en_gb => .gb,
            .es_es => .es,
            .es_mx, .es_ar, .es_co, .es_cl, .es_pe => .latam,
            .zh_cn => .pinyin,
            .fr_fr => .fr,
            .de_de => .de,
            .pt_br => .br,
            .pt_pt => .pt,
            .ja_jp => .romaji,
            .ar_eg => .ar,
            // Canada's French keyboard is QWERTY: the US one, to start.
            else => .us,
        };
    }

    pub const Clock = enum {
        /// 18:05
        @"24_hour",
        /// 6:05 PM
        @"12_hour_upper",
        /// 6:05 pm
        @"12_hour_lower",
        /// 6:05 p. m.
        @"12_hour_spanish",
        /// 6:05 م
        @"12_hour_arabic",
    };

    pub fn clock(l: Language) Clock {
        return switch (l) {
            .en_gb, .es_es, .es_ar, .es_cl, .zh_cn, .fr_fr, .fr_ca, .de_de, .pt_br, .pt_pt, .ja_jp => .@"24_hour",
            .en_us, .en_ca => .@"12_hour_upper",
            .en_au, .en_nz => .@"12_hour_lower",
            .es_mx, .es_co, .es_pe, .es_us => .@"12_hour_spanish",
            .ar_eg => .@"12_hour_arabic",
        };
    }

    /// Dates with the month first: "Oct 7" rather than "7 Oct".
    pub fn monthFirst(l: Language) bool {
        return l == .en_us or l == .en_ca;
    }

    /// Temperatures in Fahrenheit.
    pub fn fahrenheit(l: Language) bool {
        return l == .en_us or l == .es_us;
    }
};

/// The keyboard layouts: which character each key types (by Linux key
/// code), alone, with Shift, and with AltGr (the right Alt).
pub const Keyboard = enum {
    us,
    gb,
    es,
    latam,
    /// A US keyboard, typing Chinese through kete's pinyin input method.
    pinyin,
    fr,
    de,
    br,
    pt,
    /// A US keyboard, typing Japanese through kete's romaji input method.
    romaji,
    /// Arabic (the standard layout, with Western digits).
    ar,

    pub fn name(k: Keyboard) []const u8 {
        return switch (k) {
            .us => "English (US)",
            .gb => "English (UK)",
            .es => "Español (España)",
            .latam => "Español (Latinoamérica)",
            .pinyin => "中文（拼音）",
            .fr => "Français (AZERTY)",
            .de => "Deutsch (QWERTZ)",
            .br => "Português (Brasil, ABNT2)",
            .pt => "Português (Portugal)",
            .romaji => "日本語（ローマ字）",
            .ar => "العربية",
        };
    }

    /// Whether its keyboards are ISO's shape (an extra key beside the left
    /// Shift, and a tall Enter), as Europe's and Latin America's are,
    /// rather than ANSI's (as the US's).
    pub fn iso(k: Keyboard) bool {
        return switch (k) {
            .gb, .es, .latam, .fr, .de, .br, .pt => true,
            .us, .pinyin, .romaji, .ar => false,
        };
    }

    /// The language pack with its full input method (see the shell's
    /// ime.zig), if it has one: the code it is published by.
    pub fn languagePack(k: Keyboard) ?[]const u8 {
        return switch (k) {
            .romaji => "ja",
            else => null,
        };
    }

    /// Its XKB name.
    pub fn code(k: Keyboard) []const u8 {
        return @tagName(k);
    }

    pub fn fromCode(text_: []const u8) ?Keyboard {
        return std.meta.stringToEnum(Keyboard, text_);
    }

    /// The keys that type characters, and what they type.
    pub fn keys(k: Keyboard) []const Key {
        return switch (k) {
            .us => &us_keys,
            .gb => &gb_keys,
            .es => &es_keys,
            .latam => &latam_keys,
            .pinyin => &us_keys,
            .fr => &fr_keys,
            .de => &de_keys,
            .br => &br_keys,
            .pt => &pt_keys,
            .romaji => &us_keys,
            .ar => &ar_keys,
        };
    }

    /// The character a key types, if it types one. Caps Lock shifts
    /// letters only.
    pub fn char(k: Keyboard, key_code: u32, shift: bool, caps: bool, altgr: bool) ?u21 {
        for (k.keys()) |key| if (key.code == key_code) {
            if (altgr) return key.altgr;
            const letter = key.capsLetter();
            const up = if (letter) shift != caps else shift;
            return if (up) key.shifted else key.plain;
        };
        if (altgr) return null;
        return switch (key_code) {
            55 => '*',
            71 => '7',
            72 => '8',
            73 => '9',
            74 => '-',
            75 => '4',
            76 => '5',
            77 => '6',
            78 => '+',
            79 => '1',
            80 => '2',
            81 => '3',
            82 => '0',
            83 => '.',
            98 => '/',
            117 => '=',
            else => null,
        };
    }
};

pub const Key = struct {
    code: u8,
    plain: u21,
    shifted: u21,
    altgr: ?u21 = null,

    /// Whether Caps Lock types it as with Shift: a letter, its capital with
    /// Shift (not ç on a French keyboard, which types 9).
    pub fn capsLetter(k: Key) bool {
        if (k.plain >= 'a' and k.plain <= 'z') return k.shifted == k.plain - 32;
        return switch (k.plain) {
            'ñ', 'ç', 'ü', 'ö', 'ä' => k.shifted == k.plain - 32,
            else => false,
        };
    }
};

/// The keys of a US keyboard's rows, by Linux key code.
fn row(comptime first: u8, comptime plain: []const u8, comptime shifted: []const u8) [codepoints(plain).len]Key {
    const p = codepoints(plain);
    const s = codepoints(shifted);
    var out: [p.len]Key = undefined;
    for (&out, p, s, 0..) |*k, pc, sc, i| k.* = .{ .code = first + i, .plain = pc, .shifted = sc };
    return out;
}

/// `chars`'s characters (it is UTF-8).
fn codepoints(comptime chars: []const u8) [std.unicode.utf8CountCodepoints(chars) catch unreachable]u21 {
    var out: [std.unicode.utf8CountCodepoints(chars) catch unreachable]u21 = undefined;
    var it = (std.unicode.Utf8View.init(chars) catch unreachable).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |c| : (i += 1) out[i] = c;
    return out;
}

const us_keys = row(2, "1234567890-=", "!@#$%^&*()_+") ++
    row(16, "qwertyuiop[]", "QWERTYUIOP{}") ++
    row(30, "asdfghjkl;'`", "ASDFGHJKL:\"~") ++
    [_]Key{.{ .code = 43, .plain = '\\', .shifted = '|' }} ++
    row(44, "zxcvbnm,./", "ZXCVBNM<>?") ++
    [_]Key{
        .{ .code = 57, .plain = ' ', .shifted = ' ' },
        // The key beside the left Shift, on keyboards that have one.
        .{ .code = 86, .plain = '<', .shifted = '>' },
    };

/// The standard Arabic keyboard (XKB's "ara"), with Western digits: Arabic
/// letters, and with Shift the harakat and punctuation. Lam-alef, a key of
/// its own, types its ligature's presentation form (one character here).
const ar_keys = blk: {
    @setEvalBranchQuota(20_000);
    break :blk row(2, "1234567890-=", "!@#$%^&*()_+") ++
    row(16, "ضصثقفغعهخحجد", "\u{064E}\u{064B}\u{064F}\u{064C}\u{FEF9}إ‘÷×؛<>") ++
    row(30, "شسيبلاتنمكطذ", "\u{0650}\u{064D}][\u{FEF7}أـ،/:\"\u{0651}") ++
    [_]Key{.{ .code = 43, .plain = '\\', .shifted = '|' }} ++
    row(44, "ئءؤر\u{FEFB}ىةوزظ", "~\u{0652}}{\u{FEF5}آ’,.؟") ++
    [_]Key{
        .{ .code = 57, .plain = ' ', .shifted = ' ' },
        .{ .code = 86, .plain = '<', .shifted = '>' },
    };
};

/// A UK keyboard: the US one with ", £, @, ¬ and # where the UK has them,
/// the extra key beside the left Shift, and the euro on AltGr+4.
const gb_keys = blk: {
    var keys = us_keys;
    for (&keys) |*k| switch (k.code) {
        3 => k.shifted = '"',
        4 => k.shifted = '£',
        5 => k.altgr = '€',
        40 => k.shifted = '@',
        41 => {
            k.shifted = '¬';
            k.altgr = '¦';
        },
        43 => {
            k.plain = '#';
            k.shifted = '~';
        },
        86 => {
            k.plain = '\\';
            k.shifted = '|';
        },
        else => {},
    };
    break :blk keys;
};

/// Spanish (Spain): ñ and ç, ¡ and ¿, and accents as dead keys (` and ^
/// on the key after P, ´ and ¨ on the key after Ñ: then the letter); on
/// AltGr, | @ # ~ € ¬ over the numbers, and € on E.
const es_keys = blk: {
    var keys = row(2, "1234567890'¡", "!\"·$%&/()=?¿") ++
        row(16, "qwertyuiop", "QWERTYUIOP") ++
        [_]Key{
            .{ .code = 26, .plain = dead_grave, .shifted = dead_circumflex, .altgr = '[' },
            .{ .code = 27, .plain = '+', .shifted = '*', .altgr = ']' },
        } ++
        row(30, "asdfghjkl", "ASDFGHJKL") ++
        [_]Key{
            .{ .code = 39, .plain = 'ñ', .shifted = 'Ñ' },
            .{ .code = 40, .plain = dead_acute, .shifted = dead_diaeresis, .altgr = '{' },
            .{ .code = 41, .plain = 'º', .shifted = 'ª', .altgr = '\\' },
            .{ .code = 43, .plain = 'ç', .shifted = 'Ç', .altgr = '}' },
        } ++
        row(44, "zxcvbnm,.-", "ZXCVBNM;:_") ++
        [_]Key{
            .{ .code = 57, .plain = ' ', .shifted = ' ' },
            .{ .code = 86, .plain = '<', .shifted = '>' },
        };
    for (&keys) |*k| k.altgr = switch (k.code) {
        2 => '|',
        3 => '@',
        4 => '#',
        5 => '~',
        6, 18 => '€',
        7 => '¬',
        else => k.altgr,
    };
    break :blk keys;
};

/// Latin American Spanish: ñ, ¿ and ¡, ´ and ¨ as dead keys (the key
/// after P), and @ on AltGr+Q.
const latam_keys = blk: {
    var keys = row(2, "1234567890'¿", "!\"#$%&/()=?¡") ++
        row(16, "qwertyuiop", "QWERTYUIOP") ++
        [_]Key{
            .{ .code = 26, .plain = dead_acute, .shifted = dead_diaeresis },
            .{ .code = 27, .plain = '+', .shifted = '*', .altgr = '~' },
        } ++
        row(30, "asdfghjkl", "ASDFGHJKL") ++
        [_]Key{
            .{ .code = 39, .plain = 'ñ', .shifted = 'Ñ' },
            .{ .code = 40, .plain = '{', .shifted = '[', .altgr = '^' },
            .{ .code = 41, .plain = '|', .shifted = '°', .altgr = '¬' },
            .{ .code = 43, .plain = '}', .shifted = ']', .altgr = '`' },
        } ++
        row(44, "zxcvbnm,.-", "ZXCVBNM;:_") ++
        [_]Key{
            .{ .code = 57, .plain = ' ', .shifted = ' ' },
            .{ .code = 86, .plain = '<', .shifted = '>' },
        };
    for (&keys) |*k| if (k.code == 16) {
        k.altgr = '@';
    };
    break :blk keys;
};

/// French (France), AZERTY: é è ç à on the number keys (the digits with
/// Shift), ^ and ¨ as dead keys, ù, and on AltGr ~ # { [ | ` \ ^ @ ] }
/// and €.
const fr_keys = blk: {
    var keys = row(2, "&é\"'(-è_çà)=", "1234567890°+") ++
        row(16, "azertyuiop", "AZERTYUIOP") ++
        [_]Key{
            .{ .code = 26, .plain = dead_circumflex, .shifted = dead_diaeresis },
            .{ .code = 27, .plain = '$', .shifted = '£', .altgr = '¤' },
        } ++
        row(30, "qsdfghjklm", "QSDFGHJKLM") ++
        [_]Key{
            .{ .code = 40, .plain = 'ù', .shifted = '%' },
            .{ .code = 41, .plain = '²', .shifted = '³' },
            .{ .code = 43, .plain = '*', .shifted = 'µ' },
        } ++
        row(44, "wxcvbn,;:!", "WXCVBN?./§") ++
        [_]Key{
            .{ .code = 57, .plain = ' ', .shifted = ' ' },
            .{ .code = 86, .plain = '<', .shifted = '>' },
        };
    for (&keys) |*k| k.altgr = switch (k.code) {
        3 => '~',
        4 => '#',
        5 => '{',
        6 => '[',
        7 => '|',
        8 => '`',
        9 => '\\',
        10 => '^',
        11 => '@',
        12 => ']',
        13 => '}',
        18 => '€',
        else => k.altgr,
    };
    break :blk keys;
};

/// German (Germany), QWERTZ: ß, ü, ö and ä, ^ ´ and ` as dead keys, and
/// on AltGr @ (Q), € (E), ² ³ { [ ] } \ ~ | and µ.
const de_keys = blk: {
    var keys = row(2, "1234567890ß", "!\"§$%&/()=?") ++
        [_]Key{.{ .code = 13, .plain = dead_acute, .shifted = dead_grave }} ++
        row(16, "qwertzuiop", "QWERTZUIOP") ++
        [_]Key{
            .{ .code = 26, .plain = 'ü', .shifted = 'Ü' },
            .{ .code = 27, .plain = '+', .shifted = '*', .altgr = '~' },
        } ++
        row(30, "asdfghjkl", "ASDFGHJKL") ++
        [_]Key{
            .{ .code = 39, .plain = 'ö', .shifted = 'Ö' },
            .{ .code = 40, .plain = 'ä', .shifted = 'Ä' },
            .{ .code = 41, .plain = dead_circumflex, .shifted = '°' },
            .{ .code = 43, .plain = '#', .shifted = '\'' },
        } ++
        row(44, "yxcvbnm,.-", "YXCVBNM;:_") ++
        [_]Key{
            .{ .code = 57, .plain = ' ', .shifted = ' ' },
            .{ .code = 86, .plain = '<', .shifted = '>', .altgr = '|' },
        };
    for (&keys) |*k| k.altgr = switch (k.code) {
        3 => '²',
        4 => '³',
        8 => '{',
        9 => '[',
        10 => ']',
        11 => '}',
        12 => '\\',
        16 => '@',
        18 => '€',
        50 => 'µ',
        else => k.altgr,
    };
    break :blk keys;
};

/// Portuguese (Brazil), ABNT2: ç, ´ ` ~ ^ and ¨ as dead keys, and on
/// AltGr / ? ° (Q W E), ¹ ² ³ £ ¢ ¬ §, ª and º.
const br_keys = blk: {
    var keys = row(2, "12345", "!@#$%") ++
        [_]Key{.{ .code = 7, .plain = '6', .shifted = dead_diaeresis }} ++
        row(8, "7890-=", "&*()_+") ++
        row(16, "qwertyuiop", "QWERTYUIOP") ++
        [_]Key{
            .{ .code = 26, .plain = dead_acute, .shifted = dead_grave },
            .{ .code = 27, .plain = '[', .shifted = '{', .altgr = 'ª' },
        } ++
        row(30, "asdfghjkl", "ASDFGHJKL") ++
        [_]Key{
            .{ .code = 39, .plain = 'ç', .shifted = 'Ç' },
            .{ .code = 40, .plain = dead_tilde, .shifted = dead_circumflex },
            .{ .code = 41, .plain = '\'', .shifted = '"' },
            .{ .code = 43, .plain = ']', .shifted = '}', .altgr = 'º' },
        } ++
        row(44, "zxcvbnm,.;", "ZXCVBNM<>:") ++
        [_]Key{
            .{ .code = 57, .plain = ' ', .shifted = ' ' },
            .{ .code = 86, .plain = '\\', .shifted = '|' },
        };
    for (&keys) |*k| k.altgr = switch (k.code) {
        2 => '¹',
        3 => '²',
        4 => '³',
        5 => '£',
        6 => '¢',
        7 => '¬',
        13 => '§',
        16 => '/',
        17 => '?',
        18 => '°',
        else => k.altgr,
    };
    break :blk keys;
};

/// Portuguese (Portugal): ç, º and ª, ´ ` ~ and ^ as dead keys, « and »,
/// and on AltGr @ £ § { [ ] } and €.
const pt_keys = blk: {
    var keys = row(2, "1234567890'«", "!\"#$%&/()=?»") ++
        row(16, "qwertyuiop", "QWERTYUIOP") ++
        [_]Key{
            .{ .code = 26, .plain = '+', .shifted = '*' },
            .{ .code = 27, .plain = dead_acute, .shifted = dead_grave },
        } ++
        row(30, "asdfghjkl", "ASDFGHJKL") ++
        [_]Key{
            .{ .code = 39, .plain = 'ç', .shifted = 'Ç' },
            .{ .code = 40, .plain = 'º', .shifted = 'ª' },
            .{ .code = 41, .plain = '\\', .shifted = '|' },
            .{ .code = 43, .plain = dead_tilde, .shifted = dead_circumflex },
        } ++
        row(44, "zxcvbnm,.-", "ZXCVBNM;:_") ++
        [_]Key{
            .{ .code = 57, .plain = ' ', .shifted = ' ' },
            .{ .code = 86, .plain = '<', .shifted = '>' },
        };
    for (&keys) |*k| k.altgr = switch (k.code) {
        3 => '@',
        4 => '£',
        5 => '§',
        8 => '{',
        9 => '[',
        10 => ']',
        11 => '}',
        18 => '€',
        else => k.altgr,
    };
    break :blk keys;
};

// --- Accents typed with dead keys ------------------------------------------------

/// Dead keys, as the combining accents they put on the next letter.
pub const dead_grave: u21 = 0x300;
pub const dead_acute: u21 = 0x301;
pub const dead_circumflex: u21 = 0x302;
pub const dead_tilde: u21 = 0x303;
pub const dead_diaeresis: u21 = 0x308;

/// Whether a key types a dead key (an accent for the next letter).
pub fn isDead(c: u21) bool {
    return switch (c) {
        dead_grave, dead_acute, dead_circumflex, dead_tilde, dead_diaeresis => true,
        else => false,
    };
}

/// `dead` then `c`: the letter with the accent, if there is one (é), or
/// the accent alone if `c` is a space or the dead key again; null if they
/// do not go together (the accent and the key are then typed as they are).
pub fn compose(dead: u21, c: u21) ?u21 {
    if (c == ' ' or c == dead) return spacing(dead);
    const bases = "aeiouAEIOUnNcC";
    const table = switch (dead) {
        dead_acute => "áéíóúÁÉÍÓÚ",
        dead_grave => "àèìòùÀÈÌÒÙ",
        dead_circumflex => "âêîôûÂÊÎÔÛ",
        dead_diaeresis => "äëïöüÄËÏÖÜ",
        dead_tilde => "ãẽĩõũÃẼĨÕŨñÑ",
        else => return null,
    };
    const at = std.mem.indexOfScalar(u8, bases, std.math.cast(u8, c) orelse return null) orelse return null;
    var it = (std.unicode.Utf8View.init(table) catch return null).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) if (i == at) return cp;
    return null;
}

/// A dead key's accent on its own (typed with a space).
pub fn spacing(dead: u21) u21 {
    return switch (dead) {
        dead_grave => '`',
        dead_acute => '´',
        dead_circumflex => '^',
        dead_tilde => '~',
        dead_diaeresis => '¨',
        else => dead,
    };
}

/// A letter (as Caps Lock shifts): a to z, ñ and ç.
pub fn isLetter(c: u21) bool {
    return (c >= 'a' and c <= 'z') or c == 'ñ' or c == 'ç';
}

// --- The choice, kept ------------------------------------------------------------

/// Where the choice is kept (written by the system manager, readable by
/// everyone).
pub const settings_file = "/data/system/locale";

pub const Settings = struct {
    language: Language = .en_us,
    keyboard: Keyboard = .us,
    timezone: TimeZone = .utc,

    /// "language en-GB\nkeyboard gb\ntimezone Europe/London\n"; what is
    /// missing or not known stays as it is by default.
    pub fn parse(text_: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.tokenizeScalar(u8, text_, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const key = f.next() orelse continue;
            const value = f.next() orelse continue;
            if (std.mem.eql(u8, key, "language")) {
                if (Language.fromCode(value)) |l| s.language = l;
            } else if (std.mem.eql(u8, key, "keyboard")) {
                if (Keyboard.fromCode(value)) |k| s.keyboard = k;
            } else if (std.mem.eql(u8, key, "timezone")) {
                if (TimeZone.fromName(value)) |z| s.timezone = z;
            }
        }
        return s;
    }

    pub fn write(s: Settings, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "language {s}\nkeyboard {s}\ntimezone {s}\n", .{ s.language.code(), s.keyboard.code(), s.timezone.name() }) catch "";
    }
};

/// The settings kept (the defaults, if there are none yet).
pub fn load() Settings {
    return loadFrom(settings_file);
}

pub fn loadFrom(path: [*:0]const u8) Settings {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return .{};
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [256]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return .{};
    return Settings.parse(buf[0..n]);
}

// --- What the app shows -------------------------------------------------------------

/// The language the app's text and formats are in (apps set it from the
/// settings: British English, the text's own, until they do).
pub var current: Language = .en_gb;

/// `s` (Dazzle's British English) in the current language.
pub fn text(comptime s: []const u8) []const u8 {
    return switch (current) {
        inline else => |l| comptime textIn(l, s),
    };
}

/// `fmt` (a format, in British English) in the current language, with
/// `args`, into `buf`: the translation keeps the format's arguments, in
/// order.
pub fn bufPrint(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return switch (current) {
        inline else => |l| std.fmt.bufPrint(buf, comptime textIn(l, fmt), args) catch "",
    };
}

/// `s` in language `l`. Every text shown in Spanish has its translation
/// (spanish.zig): one missing is an error when it is built.
pub fn textIn(comptime l: Language, comptime s: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    if (l == .en_us) return lookup(&us_spelling, s) orelse s;
    if (l.family() == .english or !hasWords(s)) return s;
    // The country's own words, if it has any for it, then the language's.
    const own: ?[]const u8 = switch (l) {
        .es_es => lookup(&spanish.spain, s),
        .fr_ca => lookup(&french.canada, s),
        .pt_pt => lookup(&portuguese.portugal, s),
        else => null,
    };
    if (own) |t| return t;
    const t = switch (l.family()) {
        .english => unreachable,
        .spanish => lookup(&spanish.latin_america, s),
        .chinese => lookup(&chinese.simplified, s),
        .french => lookup(&french.france, s),
        .german => lookup(&german.germany, s),
        .portuguese => lookup(&portuguese.brazil, s),
        .japanese => lookup(&japanese.japan, s),
        .arabic => lookup(&arabic.arabic, s),
    };
    return t orelse @compileError("no " ++ @tagName(l.family()) ++ " for \"" ++ s ++ "\" (see " ++ @tagName(l.family()) ++ ".zig)");
}

/// Whether `s` has words to translate: letters outside its format's
/// arguments ("{s} · {s}" has none).
fn hasWords(comptime s: []const u8) bool {
    var in_arg = false;
    for (s) |c| {
        if (c == '{') in_arg = true else if (c == '}') in_arg = false else if (!in_arg and std.ascii.isAlphabetic(c)) return true;
    }
    return false;
}

fn lookup(table: []const [2][]const u8, comptime s: []const u8) ?[]const u8 {
    for (table) |pair| if (std.mem.eql(u8, pair[0], s)) return pair[1];
    return null;
}

/// The Spanish translations.
pub const spanish = @import("spanish.zig");
/// The other languages' translations.
pub const chinese = @import("chinese.zig");
pub const french = @import("french.zig");
pub const german = @import("german.zig");
pub const portuguese = @import("portuguese.zig");
pub const japanese = @import("japanese.zig");
pub const arabic = @import("arabic.zig");

/// The kinds of language, by their words and ways.
pub const Family = enum { english, spanish, chinese, french, german, portuguese, japanese, arabic };

/// American spelling, where it differs (Canada spells as Britain does).
const us_spelling = [_][2][]const u8{
    .{ "colour", "color" },
    .{ "16-bit colour", "16-bit color" },
};

/// A language's words for the calendar, and how its dates are written.
const Calendar = struct {
    months: [12][]const u8,
    months_long: [12][]const u8,
    weekdays: [7][]const u8,
    today: []const u8,
    yesterday: []const u8,
};

const calendars = std.enums.directEnumArray(Family, Calendar, 0, .{
    .english = .{
        .months = .{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" },
        .months_long = .{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
        .weekdays = .{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" },
        .today = "Today",
        .yesterday = "Yesterday",
    },
    // Spanish, French and Portuguese write them in lower case.
    .spanish = .{
        .months = .{ "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic" },
        .months_long = .{ "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre" },
        .weekdays = .{ "domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado" },
        .today = "Hoy",
        .yesterday = "Ayer",
    },
    .chinese = .{
        .months = .{ "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
        .months_long = .{ "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
        .weekdays = .{ "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" },
        .today = "今天",
        .yesterday = "昨天",
    },
    .french = .{
        .months = .{ "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc." },
        .months_long = .{ "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre" },
        .weekdays = .{ "dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi" },
        .today = "Aujourd’hui",
        .yesterday = "Hier",
    },
    .german = .{
        .months = .{ "Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez." },
        .months_long = .{ "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember" },
        .weekdays = .{ "Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag" },
        .today = "Heute",
        .yesterday = "Gestern",
    },
    .portuguese = .{
        .months = .{ "jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez." },
        .months_long = .{ "janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro" },
        .weekdays = .{ "domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado" },
        .today = "Hoje",
        .yesterday = "Ontem",
    },
    .japanese = .{
        .months = .{ "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
        .months_long = .{ "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
        .weekdays = .{ "日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日" },
        .today = "今日",
        .yesterday = "昨日",
    },
    // Egypt's names for the months.
    .arabic = .{
        .months = .{ "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر" },
        .months_long = .{ "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر" },
        .weekdays = .{ "الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت" },
        .today = "اليوم",
        .yesterday = "أمس",
    },
});

fn calendar() *const Calendar {
    return &calendars[@intFromEnum(current.family())];
}

/// A day of the week's name (0: Sunday), in the current language.
pub fn weekdayName(d: u3) []const u8 {
    return calendar().weekdays[@min(d, 6)];
}

/// The ending a count's word takes: "s" for more than one (or none) in
/// English, Spanish, French and Portuguese ("5 minutes", "5 minutos");
/// none in Chinese or German (whose translations say the word whole).
pub fn plural(n: anytype) []const u8 {
    return switch (current.family()) {
        .chinese, .german, .japanese, .arabic => "",
        else => if (n == 1) "" else "s",
    };
}

/// A date in full, with its day of the week: "Monday, 16 November 2026",
/// "lunes, 16 de noviembre de 2026", "lundi 16 novembre 2026" or
/// "2026年11月16日 星期一".
pub fn formatFullDate(buf: []u8, weekday: u3, day: u32, month: u32, year: u32) []const u8 {
    var date_buf: [48]u8 = undefined;
    const date = formatLongDate(&date_buf, day, month, year);
    return switch (current.family()) {
        .chinese, .japanese => std.fmt.bufPrint(buf, "{s} {s}", .{ date, weekdayName(weekday) }),
        .french => std.fmt.bufPrint(buf, "{s} {s}", .{ weekdayName(weekday), date }),
        .arabic => std.fmt.bufPrint(buf, "{s}، {s}", .{ weekdayName(weekday), date }),
        else => std.fmt.bufPrint(buf, "{s}, {s}", .{ weekdayName(weekday), date }),
    } catch "";
}

/// A time of day: "18:05", "6:05 PM", "6:05 pm" or "6:05 p. m.".
pub fn formatClock(buf: []u8, hour: u32, minute: u32) []const u8 {
    const h12 = if (hour % 12 == 0) 12 else hour % 12;
    return switch (current.clock()) {
        .@"24_hour" => std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hour, minute }),
        .@"12_hour_upper" => std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, minute, if (hour < 12) "AM" else "PM" }),
        .@"12_hour_lower" => std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, minute, if (hour < 12) "am" else "pm" }),
        .@"12_hour_spanish" => std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, minute, if (hour < 12) "a. m." else "p. m." }),
        .@"12_hour_arabic" => std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, minute, if (hour < 12) "ص" else "م" }),
    } catch "";
}

/// A date: "7 Oct", "Oct 7", "7 oct", "7. Okt." or "10月7日", with the
/// year ("7 Oct 2025", "Oct 7, 2025", "2025年10月7日") if `year` is given.
pub fn formatDate(buf: []u8, day: u32, month: u32, year: ?u32) []const u8 {
    const m = calendar().months[@min(month, 12) -| 1];
    return (switch (current.family()) {
        .chinese, .japanese => if (year) |y| std.fmt.bufPrint(buf, "{d}年{d}月{d}日", .{ y, month, day }) else std.fmt.bufPrint(buf, "{d}月{d}日", .{ month, day }),
        .german => if (year) |y| std.fmt.bufPrint(buf, "{d}. {s} {d}", .{ day, m, y }) else std.fmt.bufPrint(buf, "{d}. {s}", .{ day, m }),
        .portuguese => if (year) |y| std.fmt.bufPrint(buf, "{d} de {s} de {d}", .{ day, m, y }) else std.fmt.bufPrint(buf, "{d} de {s}", .{ day, m }),
        else => if (current.monthFirst())
            (if (year) |y| std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ m, day, y }) else std.fmt.bufPrint(buf, "{s} {d}", .{ m, day }))
        else if (year) |y| std.fmt.bufPrint(buf, "{d} {s} {d}", .{ day, m, y }) else std.fmt.bufPrint(buf, "{d} {s}", .{ day, m }),
    }) catch "";
}

/// A date in full: "7 October 2026", "October 7, 2026", "7 de octubre de
/// 2026", "7 octobre 2026", "7. Oktober 2026" or "2026年10月7日".
pub fn formatLongDate(buf: []u8, day: u32, month: u32, year: u32) []const u8 {
    const m = calendar().months_long[@min(month, 12) -| 1];
    return (switch (current.family()) {
        .chinese, .japanese => std.fmt.bufPrint(buf, "{d}年{d}月{d}日", .{ year, month, day }),
        .spanish, .portuguese => std.fmt.bufPrint(buf, "{d} de {s} de {d}", .{ day, m, year }),
        .german => std.fmt.bufPrint(buf, "{d}. {s} {d}", .{ day, m, year }),
        else => if (current.monthFirst()) std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ m, day, year }) else std.fmt.bufPrint(buf, "{d} {s} {d}", .{ day, m, year }),
    }) catch "";
}

/// When something happened, against `now` (both in seconds since 1970, in
/// UTC, the only time the system has): "Today, 10:32", "Yesterday, 6:05
/// PM", "7 Oct" this year, else "7 Oct 2025" (in the current language's
/// ways: "Hoy, 10:32", "今天 10:32").
pub fn formatWhen(buf: []u8, secs: i64, now: i64) []const u8 {
    if (secs <= 0) return "";
    const day_secs = std.time.s_per_day;
    const day = @divFloor(secs, day_secs);
    const today = @divFloor(now, day_secs);
    const in_day: u32 = @intCast(@mod(secs, day_secs));
    if (day == today or day == today - 1) {
        var clock_buf: [16]u8 = undefined;
        const clock = formatClock(&clock_buf, in_day / 3600, in_day / 60 % 60);
        const word = if (day == today) calendar().today else calendar().yesterday;
        if (current.family() == .chinese or current.family() == .japanese) return std.fmt.bufPrint(buf, "{s} {s}", .{ word, clock }) catch "";
        if (current.family() == .arabic) return std.fmt.bufPrint(buf, "{s}، {s}", .{ word, clock }) catch "";
        return std.fmt.bufPrint(buf, "{s}, {s}", .{ word, clock }) catch "";
    }
    const date = (std.time.epoch.EpochDay{ .day = @intCast(day) }).calculateYearDay();
    const md = date.calculateMonthDay();
    const this_year = (std.time.epoch.EpochDay{ .day = @intCast(@max(today, 0)) }).calculateYearDay().year;
    return formatDate(buf, md.day_index + 1, @intFromEnum(md.month), if (date.year == this_year) null else date.year);
}

/// A temperature, given in Celsius: "48.3 °C", or "118.9 °F".
pub fn formatTemperature(buf: []u8, celsius: f32) []const u8 {
    if (current.fahrenheit()) return std.fmt.bufPrint(buf, "{d:.1} °F", .{celsius * 9 / 5 + 32}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} °C", .{celsius}) catch "";
}

// --- Tests -------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = timezone;
}

test "every language is in by_speakers once, and says hello" {
    for (std.enums.values(Language)) |l| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(Language, &Language.by_speakers, &.{l}));
        try std.testing.expect(l.hello().len > 0);
    }
}

test "keyboards" {
    // US.
    try testing.expectEqual(@as(?u21, 'a'), Keyboard.us.char(30, false, false, false));
    try testing.expectEqual(@as(?u21, 'A'), Keyboard.us.char(30, true, false, false));
    try testing.expectEqual(@as(?u21, 'A'), Keyboard.us.char(30, false, true, false));
    try testing.expectEqual(@as(?u21, '1'), Keyboard.us.char(2, false, true, false));
    try testing.expectEqual(@as(?u21, '@'), Keyboard.us.char(3, true, false, false));
    try testing.expectEqual(@as(?u21, '#'), Keyboard.us.char(4, true, false, false));
    try testing.expectEqual(@as(?u21, '"'), Keyboard.us.char(40, true, false, false));
    try testing.expectEqual(@as(?u21, '\\'), Keyboard.us.char(43, false, false, false));
    try testing.expectEqual(@as(?u21, ' '), Keyboard.us.char(57, false, false, false));
    try testing.expectEqual(@as(?u21, null), Keyboard.us.char(1, false, false, false));
    try testing.expectEqual(@as(?u21, null), Keyboard.us.char(5, false, false, true));
    // UK.
    try testing.expectEqual(@as(?u21, '"'), Keyboard.gb.char(3, true, false, false));
    try testing.expectEqual(@as(?u21, '£'), Keyboard.gb.char(4, true, false, false));
    try testing.expectEqual(@as(?u21, '€'), Keyboard.gb.char(5, false, false, true));
    try testing.expectEqual(@as(?u21, '@'), Keyboard.gb.char(40, true, false, false));
    try testing.expectEqual(@as(?u21, '¬'), Keyboard.gb.char(41, true, false, false));
    try testing.expectEqual(@as(?u21, '#'), Keyboard.gb.char(43, false, false, false));
    try testing.expectEqual(@as(?u21, '~'), Keyboard.gb.char(43, true, false, false));
    try testing.expectEqual(@as(?u21, '\\'), Keyboard.gb.char(86, false, false, false));
    try testing.expectEqual(@as(?u21, 'q'), Keyboard.gb.char(16, false, false, false));
    // Spanish (Spain): ñ (Caps Lock too), AltGr+E and AltGr+2, and the
    // accents as dead keys.
    try testing.expectEqual(@as(?u21, 'ñ'), Keyboard.es.char(39, false, false, false));
    try testing.expectEqual(@as(?u21, 'Ñ'), Keyboard.es.char(39, false, true, false));
    try testing.expectEqual(@as(?u21, '€'), Keyboard.es.char(18, false, false, true));
    try testing.expectEqual(@as(?u21, '@'), Keyboard.es.char(3, false, false, true));
    try testing.expectEqual(@as(?u21, '¿'), Keyboard.es.char(13, true, false, false));
    try testing.expectEqual(@as(?u21, dead_acute), Keyboard.es.char(40, false, false, false));
    // Latin American: AltGr+Q.
    try testing.expectEqual(@as(?u21, '@'), Keyboard.latam.char(16, false, false, true));
    try testing.expectEqual(@as(?u21, dead_acute), Keyboard.latam.char(26, false, false, false));
    // French (AZERTY): é on 2 (1 with Shift), Caps Lock not turning ç
    // into 9, € on AltGr+E; German: ü, ß, € and @; Brazil: ç, dead ~.
    try testing.expectEqual(@as(?u21, 'é'), Keyboard.fr.char(3, false, false, false));
    try testing.expectEqual(@as(?u21, '2'), Keyboard.fr.char(3, true, false, false));
    try testing.expectEqual(@as(?u21, 'ç'), Keyboard.fr.char(10, false, true, false));
    try testing.expectEqual(@as(?u21, 'A'), Keyboard.fr.char(16, false, true, false));
    try testing.expectEqual(@as(?u21, '€'), Keyboard.fr.char(18, false, false, true));
    try testing.expectEqual(@as(?u21, 'Ü'), Keyboard.de.char(26, false, true, false));
    try testing.expectEqual(@as(?u21, 'ß'), Keyboard.de.char(12, false, false, false));
    try testing.expectEqual(@as(?u21, 'z'), Keyboard.de.char(21, false, false, false));
    try testing.expectEqual(@as(?u21, '@'), Keyboard.de.char(16, false, false, true));
    try testing.expectEqual(@as(?u21, 'Ç'), Keyboard.br.char(39, true, false, false));
    try testing.expectEqual(@as(?u21, dead_tilde), Keyboard.br.char(40, false, false, false));
    try testing.expectEqual(@as(?u21, '«'), Keyboard.pt.char(13, false, false, false));
    // Arabic: letters, and Shift's harakat.
    try testing.expectEqual(@as(?u21, 'ش'), Keyboard.ar.char(30, false, false, false));
    try testing.expectEqual(@as(?u21, 'ش'), Keyboard.ar.char(30, false, true, false));
    try testing.expectEqual(@as(?u21, 0x0650), Keyboard.ar.char(30, true, false, false));
    try testing.expectEqual(@as(?u21, 'ظ'), Keyboard.ar.char(53, false, false, false));
    // Numeric keypad.
    for ([_]u32{ 82, 79, 80, 81, 75, 76, 77, 71, 72, 73, 83, 78, 74, 55, 98, 117 }, "0123456789.+-*/=") |code, expected| {
        try testing.expectEqual(@as(?u21, expected), Keyboard.us.char(code, false, false, false));
        try testing.expectEqual(@as(?u21, expected), Keyboard.gb.char(code, false, false, false));
    }
}

test "dead keys: the accent on the next letter" {
    try testing.expectEqual(@as(?u21, 'é'), compose(dead_acute, 'e'));
    try testing.expectEqual(@as(?u21, 'Ú'), compose(dead_acute, 'U'));
    try testing.expectEqual(@as(?u21, 'ü'), compose(dead_diaeresis, 'u'));
    try testing.expectEqual(@as(?u21, 'à'), compose(dead_grave, 'a'));
    try testing.expectEqual(@as(?u21, 'ñ'), compose(dead_tilde, 'n'));
    try testing.expectEqual(@as(?u21, '´'), compose(dead_acute, ' '));
    try testing.expectEqual(@as(?u21, '^'), compose(dead_circumflex, dead_circumflex));
    try testing.expect(compose(dead_acute, 'x') == null);
    try testing.expect(isDead(dead_tilde) and !isDead('a'));
}

test "settings, kept as text" {
    var buf: [64]u8 = undefined;
    const s: Settings = .{ .language = .en_nz, .keyboard = .gb, .timezone = TimeZone.fromName("Pacific/Auckland").? };
    try testing.expectEqualStrings("language en-NZ\nkeyboard gb\ntimezone Pacific/Auckland\n", s.write(&buf));
    try testing.expectEqual(s, Settings.parse(s.write(&buf)));
    try testing.expectEqual(Settings{}, Settings.parse("language xx-XX\nkeyboard dvorak\nnonsense\n"));
    try testing.expectEqual(Language.en_ca, Settings.parse("language en-ca").language);
    try testing.expectEqual(Settings{}, loadFrom("/nonexistent/locale"));
}

test "dates, times and temperatures, in each language" {
    defer current = .en_gb;
    var buf: [32]u8 = undefined;
    // 2026-10-07 10:32 UTC.
    const now = 1791331200 + 10 * 3600 + 32 * 60;
    current = .en_gb;
    try testing.expectEqualStrings("Today, 10:32", formatWhen(&buf, now, now));
    try testing.expectEqualStrings("Yesterday, 18:05", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("1 Jan", formatWhen(&buf, 1767225600, now));
    try testing.expectEqualStrings("31 Dec 2025", formatWhen(&buf, 1767225600 - 60, now));
    try testing.expectEqualStrings("48.3 °C", formatTemperature(&buf, 48.3));
    try testing.expectEqualStrings("colour", text("colour"));
    try testing.expectEqualStrings("7 October 2026", formatLongDate(&buf, 7, 10, 2026));
    current = .en_us;
    try testing.expectEqualStrings("Today, 10:32 AM", formatWhen(&buf, now, now));
    try testing.expectEqualStrings("Yesterday, 6:05 PM", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("Today, 12:00 AM", formatWhen(&buf, 1791331200, now));
    try testing.expectEqualStrings("Jan 1", formatWhen(&buf, 1767225600, now));
    try testing.expectEqualStrings("Dec 31, 2025", formatWhen(&buf, 1767225600 - 60, now));
    try testing.expectEqualStrings("October 7, 2026", formatLongDate(&buf, 7, 10, 2026));
    try testing.expectEqualStrings("118.9 °F", formatTemperature(&buf, 48.3));
    try testing.expectEqualStrings("color", text("colour"));
    current = .en_nz;
    try testing.expectEqualStrings("Yesterday, 6:05 pm", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("7 Oct", formatDate(&buf, 7, 10, null));
    current = .en_ca;
    try testing.expectEqualStrings("Oct 7", formatDate(&buf, 7, 10, null));
    try testing.expectEqualStrings("colour", text("colour"));
    try testing.expectEqualStrings("", formatWhen(&buf, 0, now));
    // Spanish: 24 hours in Spain, a. m. and p. m. in Mexico.
    current = .es_es;
    try testing.expectEqualStrings("Hoy, 10:32", formatWhen(&buf, now, now));
    try testing.expectEqualStrings("Ayer, 18:05", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("31 dic 2025", formatWhen(&buf, 1767225600 - 60, now));
    try testing.expectEqualStrings("7 de octubre de 2026", formatLongDate(&buf, 7, 10, 2026));
    try testing.expectEqualStrings("miércoles", weekdayName(3));
    current = .es_mx;
    try testing.expectEqualStrings("Ayer, 6:05 p. m.", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("48.3 °C", formatTemperature(&buf, 48.3));
    current = .es_us;
    try testing.expectEqualStrings("118.9 °F", formatTemperature(&buf, 48.3));
    // Chinese.
    current = .zh_cn;
    try testing.expectEqualStrings("今天 10:32", formatWhen(&buf, now, now));
    try testing.expectEqualStrings("2025年12月31日", formatWhen(&buf, 1767225600 - 60, now));
    try testing.expectEqualStrings("2026年10月7日", formatLongDate(&buf, 7, 10, 2026));
    var full: [64]u8 = undefined;
    try testing.expectEqualStrings("2026年10月7日 星期三", formatFullDate(&full, 3, 7, 10, 2026));
    try testing.expectEqualStrings("设置", text("Settings"));
    try testing.expectEqualStrings("今天还剩 5 分钟", bufPrint(&full, "{d} minute{s} left today", .{ 5, plural(5) }));
    // French, German and Portuguese.
    current = .fr_fr;
    try testing.expectEqualStrings("Hier, 18:05", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("mercredi 7 octobre 2026", formatFullDate(&full, 3, 7, 10, 2026));
    try testing.expectEqualStrings("Encore 5 minutes aujourd’hui", bufPrint(&full, "{d} minute{s} left today", .{ 5, plural(5) }));
    current = .de_de;
    try testing.expectEqualStrings("Mittwoch, 7. Oktober 2026", formatFullDate(&full, 3, 7, 10, 2026));
    try testing.expectEqualStrings("31. Dez. 2025", formatWhen(&buf, 1767225600 - 60, now));
    try testing.expectEqualStrings("Heute noch 5 Min.", bufPrint(&full, "{d} minute{s} left today", .{ 5, plural(5) }));
    current = .pt_br;
    try testing.expectEqualStrings("quarta-feira, 7 de outubro de 2026", formatFullDate(&full, 3, 7, 10, 2026));
    try testing.expectEqualStrings("Configurações", text("Settings"));
    current = .pt_pt;
    try testing.expectEqualStrings("Definições", text("Settings"));
    // Portugal's own words, and Brazil's where it has none.
    try testing.expectEqualStrings("Aparência", text("Appearance"));
    // Japanese.
    current = .ja_jp;
    try testing.expectEqualStrings("昨日 18:05", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("2026年10月7日 水曜日", formatFullDate(&full, 3, 7, 10, 2026));
    try testing.expectEqualStrings("今日はあと 5 分", bufPrint(&full, "{d} minute{s} left today", .{ 5, plural(5) }));
    try testing.expectEqualStrings("設定", text("Settings"));
    // Arabic.
    current = .ar_eg;
    try testing.expectEqualStrings("أمس، 6:05 م", formatWhen(&buf, 1791331200 - 6 * 3600 + 5 * 60, now));
    try testing.expectEqualStrings("الأربعاء، 7 أكتوبر 2026", formatFullDate(&full, 3, 7, 10, 2026));
    try testing.expectEqualStrings("الإعدادات", text("Settings"));
    try testing.expect(current.rightToLeft() and !Language.ja_jp.rightToLeft());
}

test "languages" {
    try testing.expectEqual(Language.en_gb, Language.fromCode("en-GB").?);
    try testing.expect(Language.fromCode("xx-XX") == null);
    try testing.expectEqual(Language.fr_ca, Language.fromCode("fr-CA").?);
    try testing.expectEqual(Keyboard.gb, Language.en_gb.keyboard());
    try testing.expectEqual(Keyboard.us, Language.en_au.keyboard());
    try testing.expectEqual(Language.es_mx, Language.fromCode("es-MX").?);
    try testing.expectEqual(Keyboard.es, Language.es_es.keyboard());
    try testing.expectEqual(Keyboard.latam, Language.es_ar.keyboard());
    try testing.expectEqualStrings("America/Bogota", Language.es_co.timeZone().name());
    try testing.expect(Language.es_pe.spanish() and !Language.en_gb.spanish());
}
