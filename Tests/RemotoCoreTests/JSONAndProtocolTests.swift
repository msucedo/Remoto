import Foundation
import Testing
@testable import RemotoCore

@Suite struct JSONTests {
    @Test func roundTripKeepsOrderAndNumberText() throws {
        let text = #"{"b":1,"a":[2.50,-0,1e3,true,null,"x\n\"y"],"c":{}}"#
        let json = try JSON.parse(text)
        #expect(json.compact == text)
    }

    @Test func unicodeEscapesAndSurrogates() throws {
        let json = try JSON.parse(#""é😀\/""#)
        #expect(json.stringValue == "é😀/")
        #expect(throws: JSONParseError.self) { try JSON.parse(#""\ud83d""#) }
    }

    @Test func rejectsInvalidDocuments() {
        for bad in ["", "{", "[1,]", "01", "1.", "{\"a\" 1}", "tru", "\"\u{01}\"", "1 2"] {
            #expect(throws: JSONParseError.self, "\(bad)") { try JSON.parse(bad) }
        }
    }

    @Test func prettyUsesTwoSpaces() {
        let json = JSON.obj([("version", .int(1)), ("devices", .array([])), ("o", .obj([("k", .bool(true))]))])
        #expect(json.pretty == "{\n  \"version\": 1,\n  \"devices\": [],\n  \"o\": {\n    \"k\": true\n  }\n}\n")
    }

    @Test func unsignedRejectsFractionsAndSigns() throws {
        #expect(try JSON.parse("65535").unsigned(UInt16.self) == 65535)
        #expect(try JSON.parse("65536").unsigned(UInt16.self) == nil)
        #expect(try JSON.parse("1.0").unsigned(UInt16.self) == nil)
        #expect(try JSON.parse("-1").unsigned(UInt16.self) == nil)
    }
}

@Suite struct ClientMessageTests {
    func decode(_ text: String) throws -> ClientMessage { try ClientMessage.decode(text) }

    @Test func hello() throws {
        let m = try decode(
            #"{"t":"hello","v":1,"device":{"id":"abc","name":"Phone","model":"iPhone"},"auth":{"method":"pin","pin":"123 456"},"remember":true,"extra":1}"#
        )
        #expect(m == .hello(Hello(v: 1, deviceID: "abc", name: "Phone", model: "iPhone", auth: .pin("123 456"), remember: true)))
        let bare = try decode(#"{"t":"hello","v":1,"device":{"id":"abc"},"auth":{"method":"approve"}}"#)
        #expect(bare == .hello(Hello(v: 1, deviceID: "abc", name: "", model: "", auth: .approve, remember: false)))
        #expect(
            try decode(#"{"t":"hello","v":1,"device":{"id":"a"},"auth":{"method":"token","token":"t"}}"#)
                == .hello(Hello(v: 1, deviceID: "a", name: "", model: "", auth: .token("t"), remember: false)))
        #expect(
            try decode(#"{"t":"hello","v":1,"device":{"id":"a"},"auth":{"method":"pair","code":"c"}}"#)
                == .hello(Hello(v: 1, deviceID: "a", name: "", model: "", auth: .pair("c"), remember: false)))
        #expect(throws: ProtocolError.self) {
            try decode(#"{"t":"hello","v":1,"device":{"id":"a"},"auth":{"method":"magic"}}"#)
        }
    }

    @Test func inputMessages() throws {
        #expect(try decode(#"{"t":"ping","id":{"x":[1]}}"#) == .ping(id: .obj([("x", .array([.number("1")]))])))
        #expect(try decode(#"{"t":"key","code":0,"down":true}"#) == .key(code: 0, down: true, mods: 0, repeats: false))
        #expect(
            try decode(#"{"t":"key","code":57,"down":false,"mods":3,"repeat":true}"#)
                == .key(code: 57, down: false, mods: 3, repeats: true))
        #expect(try decode(#"{"t":"tap","code":36}"#) == .tap(code: 36, mods: 0))
        #expect(try decode(#"{"t":"button","button":"forward","op":"down","mods":1}"#) == .button(.forward, .down))
        #expect(try decode(#"{"t":"media","key":"illuminationToggle"}"#) == .media(.illuminationToggle, .click))
        #expect(try decode(#"{"t":"volume","value":0.5}"#) == .volume(value: 0.5, muted: nil))
        #expect(try decode(#"{"t":"volume","muted":true}"#) == .volume(value: nil, muted: true))
        #expect(try decode(#"{"t":"text","text":"hi"}"#) == .text("hi", mode: .unicode))
        #expect(try decode(#"{"t":"text","text":"hi","mode":"keystrokes"}"#) == .text("hi", mode: .keystrokes))
        #expect(try decode(#"{"t":"text","text":"hi","mode":"paste"}"#) == .text("hi", mode: .paste))
        #expect(try decode(#"{"t":"edit","delete":3,"insert":"x"}"#) == .edit(delete: 3, insert: "x"))
        #expect(try decode(#"{"t":"edit"}"#) == .edit(delete: 0, insert: ""))
        #expect(try decode(#"{"t":"release"}"#) == .release)
        #expect(throws: ProtocolError.self) { try decode(#"{"t":"key","code":70000,"down":true}"#) }
        #expect(throws: ProtocolError.self) { try decode(#"{"t":"button","button":"left","op":"hold"}"#) }
        #expect(throws: ProtocolError.self) { try decode(#"{"t":"nope"}"#) }
    }

    @Test func otherMessages() throws {
        #expect(
            try decode(#"{"t":"action","action":{"kind":"system","name":"copy"},"id":5}"#)
                == .action(.system(.copy), id: .number("5")))
        #expect(try decode(#"{"t":"action","action":{"kind":"media","key":"mute"}}"#) == .action(.media(.mute), id: nil))
        #expect(try decode(#"{"t":"apps"}"#) == .apps)
        #expect(try decode(#"{"t":"appAction","id":"com.x"}"#) == .appAction(id: "com.x", op: .toggle))
        #expect(try decode(#"{"t":"appAction","id":"com.x","op":"quit"}"#) == .appAction(id: "com.x", op: .quit))
        #expect(try decode(#"{"t":"deckSave","deck":{"version":1}}"#) == .deckSave(.obj([("version", .int(1))])))
        #expect(try decode(#"{"t":"voiceStart","locale":"es-MX"}"#) == .voiceStart(locale: "es-MX"))
        #expect(try decode(#"{"t":"voiceStart"}"#) == .voiceStart(locale: nil))
        #expect(try decode(#"{"t":"voiceStop","cancel":true}"#) == .voiceStop(cancel: true))
        #expect(try decode(#"{"t":"clipboardSet","text":"c"}"#) == .clipboardSet("c"))
        #expect(try decode(#"{"t":"clipboardGet"}"#) == .clipboardGet)
        #expect(
            try decode(#"{"t":"settingsSave","settings":{"a":1},"updatedAt":17}"#)
                == .settingsSave(settings: .obj([("a", .int(1))]), updatedAt: 17))
        #expect(try decode(#"{"t":"settingsList"}"#) == .settingsList)
        #expect(try decode(#"{"t":"settingsCopy","from":"d"}"#) == .settingsCopy(from: "d"))
    }

    @Test func binaryFrames() {
        #expect(BinaryFrame.decode(BinaryFrame.move(dx: 1.5, dy: -2).bytes) == .move(dx: 1.5, dy: -2))
        #expect(BinaryFrame.decode(BinaryFrame.scroll(phase: 2, dx: 0, dy: 3).bytes) == .scroll(phase: 2, dx: 0, dy: 3))
        #expect(BinaryFrame.decode(BinaryFrame.fling(vx: 100, vy: 0).bytes) == .fling(vx: 100, vy: 0))
        #expect(BinaryFrame.decode([0x04]) == .touch)
        #expect(BinaryFrame.decode([0x10, 1, 0]) == .audio(Data([1, 0])))
        #expect(BinaryFrame.decode([0x10, 1, 0, 2]) == nil)
        #expect(BinaryFrame.decode([0x01, 0, 0, 0, 0, 0, 0, 0]) == nil)
        var nan = BinaryFrame.move(dx: 0, dy: 0).bytes
        let bits = Float.nan.bitPattern
        nan[1...4] = [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        #expect(BinaryFrame.decode(nan) == nil)
        #expect(BinaryFrame.decode([0x7F]) == nil)
    }
}

@Suite struct ServerMessageTests {
    func text(_ m: ServerMessage) -> String { m.json.compact }

    @Test func welcomeFieldOrderAndOmissions() {
        let deck = Deck(version: 1, pages: [DeckPage(id: "p", name: "P", columns: 1, tiles: [])])
        var w = Welcome(
            hostName: "Mac", hostVersion: "1.0", sessionKey: "k", token: nil,
            features: Features(voice: true, shell: false, secure: false, permission: true), deck: deck, layout: nil,
            volume: nil, paused: false, settings: nil)
        #expect(
            text(.welcome(w))
                == #"{"t":"welcome","v":1,"host":{"name":"Mac","version":"1.0","os":"macOS"},"sessionKey":"k","token":null,"features":{"voice":true,"shell":false,"secure":false,"permission":true},"deck":{"version":1,"pages":[{"id":"p","name":"P","columns":1,"tiles":[]}]},"paused":false}"#
        )
        w.token = "tok"
        w.layout = KeyboardLayout(
            id: "us", name: "U.S.", iso: false,
            keys: [KeyCap(code: 0, base: "a", shift: "A", option: "å", optionShift: "Å", dead: 0)])
        w.volume = VolumeState(value: 0.5, muted: true)
        w.settings = StoredSettings(settings: .obj([("a", .int(1))]), updatedAt: 9)
        #expect(
            text(.welcome(w)).hasSuffix(
                #""token":"tok","features":{"voice":true,"shell":false,"secure":false,"permission":true},"deck":{"version":1,"pages":[{"id":"p","name":"P","columns":1,"tiles":[]}]},"layout":{"id":"us","name":"U.S.","iso":false,"keys":[{"code":0,"base":"a","shift":"A","option":"å","optionShift":"Å","dead":0}]},"volume":{"value":0.5,"muted":true},"paused":false,"settings":{"settings":{"a":1},"updatedAt":9}}"#
            ))
    }

    @Test func everyMessageSpelling() {
        #expect(text(.pending) == #"{"t":"pending"}"#)
        #expect(text(.denied(.wrongPin, retryAfter: nil)) == #"{"t":"denied","reason":"wrongPin"}"#)
        #expect(text(.denied(.blocked, retryAfter: 0)) == #"{"t":"denied","reason":"blocked","retryAfter":1}"#)
        #expect(text(.pong(id: .string("x"))) == #"{"t":"pong","id":"x"}"#)
        #expect(
            text(.apps([AppEntry(id: "a", name: "A", running: true, active: false, hidden: true)]))
                == #"{"t":"apps","apps":[{"id":"a","name":"A","running":true,"active":false,"hidden":true}]}"#)
        #expect(text(.appsChanged) == #"{"t":"appsChanged"}"#)
        #expect(text(.volume(VolumeState(value: 1, muted: false))) == #"{"t":"volume","value":1,"muted":false}"#)
        #expect(text(.volumeUnavailable) == #"{"t":"volumeUnavailable"}"#)
        #expect(text(.paused(true)) == #"{"t":"paused","paused":true}"#)
        #expect(
            text(.features(Features(voice: false, shell: true, secure: true, permission: false)))
                == #"{"t":"features","features":{"voice":false,"shell":true,"secure":true,"permission":false}}"#)
        #expect(
            text(.notice(.warning, code: .tooLong, message: "m"))
                == #"{"t":"notice","level":"warning","code":"tooLong","message":"m"}"#)
        #expect(text(.notice(.error, code: nil, message: "m")) == #"{"t":"notice","level":"error","message":"m"}"#)
        #expect(text(.actionResult(id: .int(3), ok: true, message: nil)) == #"{"t":"actionResult","id":3,"ok":true}"#)
        #expect(text(.actionResult(id: nil, ok: false, message: "e")) == #"{"t":"actionResult","ok":false,"message":"e"}"#)
        #expect(text(.clipboard(nil)) == #"{"t":"clipboard","text":null}"#)
        #expect(text(.bye(reason: "  ", reconnect: true)) == #"{"t":"bye","reason":"Disconnected.","reconnect":true}"#)
        #expect(
            text(.voice(VoiceUpdate(state: .listening, text: "hi", isFinal: true)))
                == #"{"t":"voice","state":"listening","text":"hi","final":true}"#)
        #expect(
            text(.settings(StoredSettings(settings: .obj([]), updatedAt: 2)))
                == #"{"t":"settings","settings":{},"updatedAt":2}"#)
        #expect(
            text(.settingsList([SettingsListItem(id: "i", name: "n", model: "m", updatedAt: 1)]))
                == #"{"t":"settingsList","devices":[{"id":"i","name":"n","model":"m","updatedAt":1}]}"#)
    }

    @Test func enumSpellings() {
        #expect(
            [DenyReason.unknown, .wrongPin, .pinClosed, .expiredCode, .rejected, .blocked, .busy, .incompatible].map(\.rawValue)
                == ["unknown", "wrongPin", "pinClosed", "expiredCode", "rejected", "blocked", "busy", "incompatible"])
        #expect(
            [NoticeCode.permission, .secureInput, .tooLong, .busy, .paused, .deck, .settings].map(\.rawValue)
                == ["permission", "secureInput", "tooLong", "busy", "paused", "deck", "settings"])
        #expect(SystemAction.allCases.count == 38)
        #expect(MediaKey.allCases.count == 13)
    }
}
