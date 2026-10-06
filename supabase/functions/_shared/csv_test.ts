import { assertEquals } from "@std/assert";
import { csvEscape, formatCell, slugify, toCsv } from "./csv.ts";

Deno.test("plain values are not quoted", () => {
  assertEquals(csvEscape("Nethmi Perera"), "Nethmi Perera");
  assertEquals(csvEscape(42), "42");
  assertEquals(csvEscape(null), "");
  assertEquals(csvEscape(undefined), "");
});

Deno.test("commas, quotes and newlines are quoted per RFC 4180", () => {
  assertEquals(csvEscape("Perera, Nethmi"), '"Perera, Nethmi"');
  assertEquals(csvEscape('She said "hi"'), '"She said ""hi"""');
  assertEquals(csvEscape("line1\nline2"), '"line1\nline2"');
  assertEquals(csvEscape("line1\r\nline2"), '"line1\r\nline2"');
  assertEquals(csvEscape(" padded "), '" padded "');
});

Deno.test("formula injection is neutralised", () => {
  assertEquals(csvEscape('=HYPERLINK("http://evil")'), '"\'=HYPERLINK(""http://evil"")"');
  assertEquals(csvEscape("+94771234567"), "'+94771234567");
  assertEquals(csvEscape("-5"), "'-5");
  assertEquals(csvEscape("@SUM(A1)"), "'@SUM(A1)");
});

Deno.test("cells format booleans, arrays and objects", () => {
  assertEquals(formatCell(true), "Yes");
  assertEquals(formatCell(false), "No");
  assertEquals(formatCell(["Software", "Data"]), "Software; Data");
  assertEquals(csvEscape(["A", "B,C"]), '"A; B,C"');
  assertEquals(formatCell({ a: 1 }), '{"a":1}');
});

Deno.test("toCsv joins rows with CRLF and keeps Unicode", () => {
  assertEquals(
    toCsv(["Reference", "Attendee name"], [["ZR-ABCDEFGH", "නෙත්මි"], ["ZR-12345678", "Kavitha, S."]]),
    'Reference,Attendee name\r\nZR-ABCDEFGH,නෙත්මි\r\nZR-12345678,"Kavitha, S."\r\n',
  );
});

Deno.test("slugify produces safe file names", () => {
  assertEquals(slugify("Jazz Under the Stars!"), "jazz-under-the-stars");
  assertEquals(slugify("Kolam & Clay Lamp Workshop"), "kolam-clay-lamp-workshop");
  assertEquals(slugify("නෙත්මි"), "event");
});
