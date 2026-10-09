# Offline announcements — 2.19.9

Today now has Announcements, Fleet and Crew Control quick actions. Calendar export is in Duty options on the briefing card. The four existing bottom tabs are unchanged.

The bundled catalogue contains 54 GetJet announcements from the supplied Public Announcements Book, issue 6 / revision 1, dated 1 February 2026. It needs no account, subscription or network request. It includes English and Lithuanian where present; controlled disembarkation (§1.5.1) is English-only in the source and is labelled accordingly.

## Crew flow

Choose a flight or browse manually; select GetJet/Airhub and A320, A321 or B737-800. A single validated roster sector supplies the aircraft type and an airline suggestion only when the registration matches an exact entry in the app's fleet list. Multiple sectors require selection; unknown types and registrations are left unselected. Crew can override either picker. With no roster sectors, manual browse choices are remembered locally. These are roster/fleet suggestions, not operator verification.

Common scripts remain available without aircraft selection. A safety demonstration or emergency briefing requires an aircraft. Only the matching demonstration and matching emergency exit paragraph are shown. Airhub is a separate empty state until its own PAB is supplied; the Airhub cabin crew manual references that separate publication.

Favorites are stored on the device and pinned above situation categories. Common favorites follow aircraft changes within the same airline; aircraft-dependent favorites are per type. Search checks titles, categories, sections and source text. The reader offers language selection, 18–34 point text, remembered paragraph position and keeps the screen awake while the reader is active. Leaving the reader or backgrounding restores the previous idle-timer setting.

## Source handling

`tools/import_getjet_announcements.py` imports the supplied PDF with PyMuPDF (developer-only dependency):

```sh
python3 tools/import_getjet_announcements.py /path/to/PUBLIC-ANNOUNCEMENTS-BOOK.pdf RAIDORoster-Web2IPA/RAIDORoster/GetJetAnnouncements.json
```

The source PDF is not committed. The catalogue records its SHA-256, revision, source section, printed start page and physical PDF pages per paragraph. A coverage check confirmed all 898 body lines are retained across 404 segments. Physical line wraps are joined; section titles are normalized for navigation. Spoken wording, placeholders and alternatives are retained. No scripts or translations are invented. Export headers/watermarks, blank pages and end-of-document text are omitted from the reading text. Original bullets are grouped into readable paragraphs.

The supplied export is marked uncontrolled. The library and reader show the source revision and remind crew to check Web Manuals. Source anomalies are retained: §2.1's Lithuanian version includes English exit paragraphs (also noted in the reader), and §2.2's Lithuanian brace paragraph contains the printed wording “antkad”. These need confirmation against an updated operator source; the app does not silently repair them. Per-page revision labels in the PDF can predate the overall book revision.

No automatic flight/crew name substitution is performed: crew fill bracketed fields and choose applicable alternatives. Airhub scripts and additional aircraft need a supplied, applicable source before addition.

## Build and review

`v2199_announcements.py` appends to the existing patch chain, registers two Swift files and the bundled JSON in Xcode, adds Today integration and advances the app version to 2.19.9. It fails on source-anchor drift. CI runs Foundation-only announcement checks, existing fleet policy checks and the complete unsigned iOS build.

Device review checklist: open from Today with no cached roster, a single flight, and a multi-sector duty; override type and airline; verify Airhub empty state; star then relaunch offline; read both languages and each demo; change text size; leave/reopen a long script; background/return; verify normal screen auto-lock returns after closing. Inspect light/dark mode and accessibility sizes on an iPhone. Automated model and compilation checks do not replace this device review.

## 2.20.7 reader layout

Refines the user's 2.20.5/2.20.6 reader without changing source wording, aircraft/language filtering or the eager (non-lazy) scrolling approach. A plain title and airline/aircraft line replace the large header card. Alternative script lines keep their exact wording with a thin accent rule and a single choice label, without tinted cards. Paragraphs have consistent spacing and become direct scroll targets. Text-size buttons remain directly accessible in a compact bottom bar beside language selection; the top toolbar contains favorite and secondary options. Source details move into an information sheet, while revision and uncontrolled-export status remain at the end of the script. The reader uses system backgrounds for light/dark appearance and keeps the existing 16–30 point preference.

`tools/preview_announcement_reader.py` renders the actual SwiftUI reader in an iPhone simulator after packaging the release IPA. It uses a disposable preview entry point with the bundled standard-boarding script, captures light/dark screenshots, restores the source, and verifies that the release IPA hash is unchanged. No roster login or personal roster data is involved. The reader screenshots are review artifacts, not a simulation of the UI in HTML.
