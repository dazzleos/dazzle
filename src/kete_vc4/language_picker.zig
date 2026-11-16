//! Choosing a language, as setup and Settings do: a field to search for
//! it (by its own name, its English name or its code, in upper or lower
//! case, with or without accents: "espanol", "mexico", "es-MX"), and the
//! languages that match, one to choose.
//!
//!     cx.make(kete_vc4.LanguagePicker{ .language = current, .on_changed = .of(st, State.setLanguage) })

const std = @import("std");
const kete = @import("kete");
const locale = @import("locale");

const Language = locale.Language;

pub const LanguagePicker = struct {
    language: Language,
    /// Called with the language chosen; without it, the choices are
    /// disabled.
    on_changed: ?kete.ValueCallback(Language) = null,
    /// How tall the list is (it scrolls if they do not all fit).
    height: f32 = 260,

    pub const State = struct {
        query_buf: [64]u8 = undefined,
        query_len: u8 = 0,

        fn setQuery(st: *State, text: []const u8) void {
            st.query_len = @intCast(@min(text.len, st.query_buf.len));
            @memcpy(st.query_buf[0..st.query_len], text[0..st.query_len]);
        }

        fn query(st: *const State) []const u8 {
            return st.query_buf[0..st.query_len];
        }
    };

    pub fn build(self: *const LanguagePicker, cx: *kete.BuildContext, st: *State) kete.Widget {
        const a = cx.arena;
        const t = cx.theme();
        var rows: std.ArrayList(kete.Widget) = .empty;
        for (std.enums.values(Language)) |l| {
            if (!matches(l, st.query())) continue;
            rows.append(a, cx.make(kete.RadioRow(Language){
                .value = l,
                .group_value = self.language,
                .on_changed = self.on_changed,
                .label = l.name(),
            })) catch {};
        }
        if (rows.items.len == 0) rows.append(a, cx.make(kete.Padding{ .padding = .all(8), .child = cx.make(kete.Text{
            .text = locale.text("No language matches"),
            .style = .{ .size = 15, .color = t.on_surface_variant },
        }) })) catch {};
        return cx.make(kete.Column{ .cross_axis_alignment = .stretch, .fill = false, .spacing = 8, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.TextField{ .placeholder = locale.text("Search"), .on_changed = .of(st, State.setQuery), .width = std.math.inf(f32) }),
            cx.make(kete.SizedBox{ .height = self.height, .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Column{
                .cross_axis_alignment = .start,
                .fill = false,
                .children = rows.items,
            }) }) }),
        }) catch &.{} });
    }
};

/// Whether `l` is found by `query`: in its name, its English name or its
/// code, ignoring case and accents. Every language is, by nothing.
pub fn matches(l: Language, query: []const u8) bool {
    const q = std.mem.trim(u8, query, " ");
    if (q.len == 0) return true;
    var qb: [64]u8 = undefined;
    const folded_q = fold(q, &qb);
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ l.name(), l.englishName(), l.code() }) |field| {
        if (std.mem.indexOf(u8, fold(field, &buf), folded_q) != null) return true;
    }
    return false;
}

/// `s` in lower case, its accented letters without their accents (á → a,
/// ñ → n), into `buf`.
fn fold(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return s).iterator();
    while (it.nextCodepoint()) |c| {
        if (n == buf.len) break;
        const plain: u8 = switch (c) {
            'á', 'à', 'â', 'ä', 'ã', 'Á', 'À', 'Â', 'Ä', 'Ã' => 'a',
            'é', 'è', 'ê', 'ë', 'É', 'È', 'Ê', 'Ë' => 'e',
            'í', 'ì', 'î', 'ï', 'Í', 'Ì', 'Î', 'Ï' => 'i',
            'ó', 'ò', 'ô', 'ö', 'õ', 'Ó', 'Ò', 'Ô', 'Ö', 'Õ' => 'o',
            'ú', 'ù', 'û', 'ü', 'Ú', 'Ù', 'Û', 'Ü' => 'u',
            'ñ', 'Ñ' => 'n',
            'ç', 'Ç' => 'c',
            else => if (c < 0x80) std.ascii.toLower(@intCast(c)) else '?',
        };
        buf[n] = plain;
        n += 1;
    }
    return buf[0..n];
}

const testing = std.testing;

test "languages found by their names, in any case and without accents" {
    try testing.expect(matches(.es_mx, "méxico"));
    try testing.expect(matches(.es_mx, "MEXICO"));
    try testing.expect(matches(.es_mx, "Spanish"));
    try testing.expect(matches(.es_mx, "espanol"));
    try testing.expect(matches(.es_mx, "es-mx"));
    try testing.expect(!matches(.en_gb, "espa"));
    try testing.expect(matches(.en_gb, "kingdom"));
    try testing.expect(matches(.en_gb, ""));
    try testing.expect(matches(.es_pe, "peru"));
}
