// ctcalign — part of Transcript Tab. Copyright (c) 2026 Inner Parakeet. MIT License (see LICENSE).
// ctcalign — places known words on the audio (CTC forced alignment).
//
// Usage: ctcalign <16 kHz mono WAV> <words.json> [--decode]
//   words.json: [[start, end, "text"], …] with approximate times (Parakeet's).
//   stdout:     [[start, end, score], …] one row per input word, same order; score = mean log
//               probability of the word's tokens (near 0 = clear, below about -8 = doubtful).
//   --decode:   print the model's own text instead (to check the model works).
//
// Model: FluidAudio's parakeet-ctc-110m-coreml (MelSpectrogram + AudioEncoder with a CTC head),
// 15 s windows, one frame of scores per 80 ms. The audio is scored in overlapping windows, the
// text is cut into pieces at long silences, and each piece is aligned with Viterbi. Times have
// 80 ms resolution; the Transcript tab fits the edges to the loudness afterwards.
import CoreML
import Foundation

let frameSec = 0.08
let winSamples = 240_000, winFrames = 188, strideFrames = 150   // 15 s windows every 12 s
let blank = 1024

func fail(_ s: String) -> Never { FileHandle.standardError.write(("ERROR:" + s + "\n").data(using: .utf8)!); exit(1) }
func note(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let args = CommandLine.arguments
guard args.count >= 3 || (args.count == 3 && args[2] == "--decode") else { fail("usage: ctcalign <wav> <words.json> [--decode]") }
let decodeOnly = args.contains("--decode")
let modelDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml")

// ---- audio
guard let wavData = FileManager.default.contents(atPath: args[1]) else { fail("can't read \(args[1])") }
var audio: [Float] = []
wavData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    var off = 12
    while off + 8 <= raw.count {
        let id = String(bytes: raw[off..<off + 4], encoding: .ascii) ?? ""
        let len = Int(raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self))
        if id == "data" {
            let n = min(len, raw.count - off - 8) / 2
            audio = [Float](repeating: 0, count: n)
            for i in 0..<n { audio[i] = Float(raw.loadUnaligned(fromByteOffset: off + 8 + 2 * i, as: Int16.self)) / 32768 }
            break
        }
        off += 8 + len + (len & 1)
    }
}
if audio.isEmpty { fail("no audio in \(args[1])") }

// ---- models
let cfg = MLModelConfiguration(); cfg.computeUnits = .all
guard let melModel = try? MLModel(contentsOf: modelDir.appendingPathComponent("MelSpectrogram.mlmodelc"), configuration: cfg),
      let encModel = try? MLModel(contentsOf: modelDir.appendingPathComponent("AudioEncoder.mlmodelc"), configuration: cfg)
else { fail("can't load the CTC model from \(modelDir.path)") }
let vocabJSON = (try? JSONSerialization.jsonObject(with: Data(contentsOf: modelDir.appendingPathComponent("vocab.json")))) as? [String: String] ?? [:]
var pieces = [String](repeating: "", count: 1024)
var pieceID: [String: Int] = [:]
for (k, v) in vocabJSON { if let i = Int(k), i < 1024 { pieces[i] = v; pieceID[v] = i } }
if pieceID.isEmpty { fail("no vocab.json") }

// ---- scores for every 80 ms frame: log probabilities [frame][1025], kept as Float16
let totalFrames = (audio.count + 1279) / 1280
var logp = [Float16](repeating: 0, count: totalFrames * 1025)
let one = try! MLMultiArray(shape: [1, 1, 1, 1], dataType: .float16)
one[0] = 1   // the encoder's second input; 1 gives the right text (checked with --decode)
var w = 0
while true {
    let start = w * strideFrames * 1280
    if start >= audio.count && w > 0 { break }
    let a = try! MLMultiArray(shape: [NSNumber(value: winSamples)], dataType: .float16)
    let ap = a.dataPointer.bindMemory(to: Float16.self, capacity: winSamples)
    for i in 0..<winSamples { let j = start + i; ap[i] = Float16(j < audio.count ? audio[j] : 0) }
    let melOut = try! melModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": a]))
    let mel = melOut.featureValue(for: "melspectrogram_features")!.multiArrayValue!
    let encOut = try! encModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["melspectrogram_features": mel, "input_1": one]))
    let ctc = encOut.featureValue(for: "ctc_head_output")!.multiArrayValue!   // [1, 1025, 1, 188]
    let cs = ctc.strides.map { $0.intValue }
    let cp = ctc.dataPointer.bindMemory(to: Float16.self, capacity: ctc.count)
    // keep the frames this window sees best: the middle, except at the file's ends
    let lo = w == 0 ? 0 : (winFrames - strideFrames) / 2
    let hi = start + winSamples >= audio.count ? winFrames : lo + strideFrames
    for f in lo..<hi {
        let g = w * strideFrames + f
        if g >= totalFrames { break }
        for c in 0..<1025 { logp[g * 1025 + c] = cp[c * cs[1] + f * cs[3]] }
    }
    if start + winSamples >= audio.count { break }
    w += 1
}
@inline(__always) func lp(_ f: Int, _ c: Int) -> Float { Float(logp[f * 1025 + c]) }

if decodeOnly {
    var text = "", prev = -1
    for f in 0..<totalFrames {
        var best = 0; var bv = -Float.infinity
        for c in 0..<1025 where lp(f, c) > bv { bv = lp(f, c); best = c }
        if best != prev && best != blank {
            let pc = pieces[best]
            text += pc.hasPrefix("▁") ? " " + String(format: "%.2f", Double(f) * frameSec) + ":" + pc.dropFirst() : pc
        }
        prev = best
    }
    print(text)   // " 12.34:word" = where each word starts
    exit(0)
}

// ---- words → tokens (greedy longest piece; -1 = "any sound", for digits and other unknowns)
guard let wordsIn = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2])))) as? [[Any]] else { fail("bad words.json") }
struct W { var s: Double; var e: Double; var toks: [Int]; var text: String }
func tokenize(_ raw: String) -> [Int] {
    let keep = raw.filter { $0.isLetter || $0 == "'" }
    if keep.isEmpty || raw.contains(where: { $0.isNumber }) { return [-1] }
    for word in [keep, keep.lowercased()] {
        var out: [Int] = [], chars = Array(word), i = 0, ok = true
        while i < chars.count {
            var found = false
            for j in stride(from: chars.count, to: i, by: -1) {
                let p = (i == 0 ? "▁" : "") + String(chars[i..<j])
                if let id = pieceID[p] { out.append(id); i = j; found = true; break }
            }
            if !found { ok = false; break }
        }
        if ok { return out }
    }
    return [-1]
}
let words: [W] = wordsIn.map { r in
    let text = r.count > 2 ? (r[2] as? String ?? "") : ""
    return W(s: (r[0] as? NSNumber)?.doubleValue ?? 0, e: (r[1] as? NSNumber)?.doubleValue ?? 0, toks: tokenize(text), text: text)
}
if words.isEmpty { print("[]"); exit(0) }

// ---- pieces of text: cut at silences (long runs of blank) near Parakeet's gaps, every 10–40 s
let isBlank: [Bool] = (0..<totalFrames).map { lp($0, blank) > -0.3 }
var runLen = [Int](repeating: 0, count: totalFrames)   // length of the blank run each frame is in
var f0 = 0
while f0 < totalFrames {
    var f1 = f0; while f1 < totalFrames && isBlank[f1] == isBlank[f0] { f1 += 1 }
    for f in f0..<f1 { runLen[f] = isBlank[f0] ? f1 - f0 : 0 }
    f0 = f1
}
func silenceNear(_ t: Double) -> (len: Int, mid: Int) {   // the longest blank run within ±0.4 s of t
    let c = Int(t / frameSec), r = 5
    var best = (len: 0, mid: c)
    for f in max(0, c - r)...min(totalFrames - 1, max(0, c + r)) where runLen[f] > best.len {
        var a = f; while a > 0 && isBlank[a - 1] { a -= 1 }
        best = (runLen[f], a + runLen[f] / 2)
    }
    return best
}
var cuts: [(word: Int, frame: Int)] = []   // a piece ends before word `word`, at frame `frame`
var pieceStart = 0, pieceT = 0.0
while pieceStart < words.count {
    var bestI = -1, best = (len: 0, mid: 0)
    var i = pieceStart
    while i + 1 < words.count {
        let t = words[i + 1].s
        if t - pieceT > 40 { break }
        if t - pieceT >= 10 { let s = silenceNear(t); if s.len > best.len { best = s; bestI = i + 1 } }
        i += 1
    }
    if i + 1 >= words.count { break }
    if bestI < 0 { bestI = i + 1; best = (0, Int(words[i + 1].s / frameSec)) }
    cuts.append((bestI, best.mid)); pieceStart = bestI; pieceT = Double(best.mid) * frameSec
}

// ---- Viterbi alignment of one piece: words[wa..<wb] onto frames fa..<fb
var outRows = [[Double]](repeating: [0, 0, -99], count: words.count)
var aligned = 0
func align(_ wa: Int, _ wb: Int, _ keep: Int, _ fa: Int, _ fb: Int) -> Int? {   // keeps words wa..<keep; returns the frame after the last
    var toks: [Int] = [], owner: [Int] = []
    for k in wa..<wb { for t in words[k].toks { toks.append(t); owner.append(k) } }
    let L = toks.count, S = 2 * L + 1, T = fb - fa
    guard L > 0, T >= L else { return nil }
    func emit(_ f: Int, _ s: Int) -> Float {
        if s % 2 == 0 { return lp(f, blank) }
        let t = toks[s / 2]
        if t >= 0 { return lp(f, t) }
        var m = -Float.infinity; for c in 0..<1024 { m = max(m, lp(f, c)) }; return m - 1   // any sound
    }
    let NEG = -Float.greatestFiniteMagnitude / 4
    var prev = [Float](repeating: NEG, count: S), cur = prev
    var back = [UInt8](repeating: 0, count: T * S)
    prev[0] = emit(fa, 0); if S > 1 { prev[1] = emit(fa, 1) }
    for f in 1..<T {
        for s in 0..<S {
            var b: UInt8 = 0, v = prev[s]
            if s >= 1 && prev[s - 1] > v { v = prev[s - 1]; b = 1 }
            if s >= 2 && s % 2 == 1 && toks[s / 2] != toks[s / 2 - 1] && prev[s - 2] > v { v = prev[s - 2]; b = 2 }
            cur[s] = v + emit(fa + f, s); back[f * S + s] = b
        }
        swap(&prev, &cur)
    }
    var s = S - 1; if S > 1 && prev[S - 2] > prev[S - 1] { s = S - 2 }
    var first = [Int](repeating: -1, count: wb - wa), last = first
    var sum = [Float](repeating: 0, count: wb - wa), cnt = [Int](repeating: 0, count: wb - wa)
    for f in stride(from: T - 1, through: 0, by: -1) {
        if s % 2 == 1 {
            let k = owner[s / 2] - wa
            if last[k] < 0 && emit(fa + f, s) >= lp(fa + f, blank) { last[k] = f }   // where the token is likelier than silence
            first[k] = f; sum[k] += emit(fa + f, s); cnt[k] += 1
        }
        s -= Int(back[f * S + s])
    }
    var after: Int? = nil
    for k in 0..<(keep - wa) where first[k] >= 0 {
        if last[k] < first[k] { last[k] = first[k] }
        after = fa + last[k] + 1
        outRows[wa + k] = [Double(fa + first[k]) * frameSec, Double(fa + last[k] + 1) * frameSec, Double(sum[k] / Float(cnt[k]))]
        aligned += 1
    }
    return after
}
var bounds = [(w: 0, f: 0)] + cuts.map { (w: $0.word, f: $0.frame) } + [(w: words.count, f: totalFrames)]
// Each piece starts where the previous piece's last word ended, and also aligns the next 8 words
// (with audio to 1.5 s past their Parakeet times) without keeping them, so its last words can't
// slide onto later speech; the next piece aligns them again. A word whose Parakeet time is a second
// off still finds its sound ("help power our future": "our" was 1.2 s late, past the cut).
var fa = 0
for p in 0..<(bounds.count - 1) {
    let wa = bounds[p].w, keep = bounds[p + 1].w
    let last = p + 2 == bounds.count
    let wb = last ? words.count : min(words.count, keep + 8)
    let fb = last ? totalFrames : min(totalFrames, max(bounds[p + 1].f, Int(words[wb - 1].e / frameSec)) + 19)
    let end = align(wa, wb, keep, fa, fb)
    if ProcessInfo.processInfo.environment["CTC_DEBUG"] != nil {
        note(String(format: "piece %d words %d-%d (+%d) frames %.2f-%.2f -> next from %.2f", p, wa, keep - 1, wb - keep, Double(fa) * frameSec, Double(fb) * frameSec, Double(end ?? -1) * frameSec))
    }
    fa = min(end ?? bounds[p + 1].f, totalFrames - 1)
}

// The model knows English only. If the words fit the audio badly overall (another language),
// keep Parakeet's times for the whole file.
let scores = outRows.map { $0[2] }.filter { $0 > -99 }.sorted()
let median = scores.isEmpty ? -99 : scores[scores.count / 2]
if median < -1.5 {   // English interviews: about -0.2; a Spanish clip: -3.7
    note("ctcalign: words don't fit the audio (median score \(String(format: "%.1f", median))), kept Parakeet's times")
    print(String(data: try! JSONSerialization.data(withJSONObject: words.map { [$0.s, $0.e, -99] }), encoding: .utf8)!)
    exit(0)
}

// The CTC model barely hears fillers (it was trained on text without them: "ACME um brought"
// decodes as "ACME brought", and "um" was placed inside "ACME"), so a filler keeps Parakeet's times
// when they start between its neighbours' aligned times. The tab then fits it to its sound (v85-v86).
let fillerWords: Set<String> = ["um", "umm", "uhm", "uh", "uhh", "er", "erm", "ah", "hmm", "hm", "mm", "mhm"]
var fillersKept = 0
for k in 0..<words.count where fillerWords.contains(words[k].text.lowercased().filter { $0.isLetter }) {
    let after = k > 0 && outRows[k - 1][2] > -99 ? outRows[k - 1][0] : -1
    let before = k + 1 < words.count && outRows[k + 1][2] > -99 ? outRows[k + 1][1] : Double.greatestFiniteMagnitude
    if words[k].s > after && words[k].s < before {
        outRows[k] = [words[k].s, words[k].e, max(outRows[k][2], -98)]; fillersKept += 1
        // the next word starts after it, as in Parakeet (else Delete on the filler leaves its tail)
        if k + 1 < words.count && outRows[k + 1][2] > -99 && outRows[k + 1][0] < words[k].e && words[k].e - outRows[k + 1][0] <= 0.3 {
            outRows[k + 1][0] = words[k].e; outRows[k + 1][1] = max(outRows[k + 1][1], words[k].e + 0.08)
        }
    }
}

// words the alignment couldn't place keep Parakeet's times
for k in 0..<words.count where outRows[k][2] <= -99 { outRows[k] = [words[k].s, words[k].e, -99] }

// CTC marks a word by one or two 80 ms frames, so widen each span for the Transcript tab's
// loudness fit (which only shrinks): the end runs on to the next word's start (at most 0.4 s),
// and the start moves back over loud 10 ms frames just before it (at most 0.16 s, not into the
// previous word). Loud = room tone + 20% of the speech range, as in the tab.
var db = [Float](repeating: 0, count: audio.count / 160)
for f in 0..<db.count {
    var s: Float = 0; for i in 0..<160 { let x = audio[f * 160 + i] * 32768; s += x * x }
    db[f] = 10 * log10(s / 160 + 1e-9)
}
let sortedDb = db.sorted()
let thr = sortedDb.isEmpty ? 0 : sortedDb[sortedDb.count / 10] + 0.2 * (sortedDb[sortedDb.count * 9 / 10] - sortedDb[sortedDb.count / 10])
let raw = outRows
func heard(_ a: Double, _ b: Double) -> Bool {   // at least 50 ms of loud 10 ms frames in [a, b)
    let lo = max(0, Int((a * 100).rounded())), hi = min(db.count, Int((b * 100).rounded()))
    var n = 0
    if lo < hi { for g in lo..<hi where db[g] > thr { n += 1 } }
    return n >= 5
}
for k in 0..<raw.count where raw[k][2] > -99 {   // starts: back over the sound's onset
    let s = raw[k][0]
    let prevEnd = k > 0 ? raw[k - 1][1] : 0
    var f = Int((s * 100).rounded()) - 1
    let lim = max(prevEnd, s - 0.16)
    while f >= 0 && f < db.count && Double(f) / 100 >= lim && db[f] > thr { f -= 1 }
    // In running speech (still loud at the limit) the loud frames before the word are mostly the
    // previous word's: move back at most one CTC frame ("is addressing": CTC 1170.56, the
    // model's own decoding 1170.62; moving back 0.16 s put it at 1170.48 and "addressing" showed
    // before a cut at 1170.60, 2026-10-27).
    // (Not after a filler: fillers keep Parakeet's times and the tab's filler rules fit them.)
    let afterFiller = k > 0 && fillerWords.contains(words[k - 1].text.lowercased().filter { $0.isLetter })
    if !afterFiller && f >= 0 && f < db.count && db[f] > thr { f = max(f, Int(((s - 0.08) * 100).rounded()) - 1) }
    let ns = min(s, Double(f + 1) / 100)
    // Not if that leaves the previous word on silence: CTC sometimes puts a short word a frame or
    // two before its sound ("with uh the": "uh" 1502.00-1502.08, its sound 1502.24-1502.40),
    // and that sound is the previous word's.
    if k > 0 && ns < s && !heard(outRows[k - 1][0], ns) { continue }
    outRows[k][0] = ns
}
// Ends: on to the next word (at most 0.4 s). A word with sound of its own stops where the next
// word's sound starts ("put" | "solar"); one with none yet may run to where CTC put the next word,
// (the next word's start was then left where CTC put it, above), and the loudness fit then moves
// it onto its sound.
for k in 0..<raw.count where raw[k][2] > -99 {
    let e = raw[k][1]
    var next = e + 0.4, cap = 0.4
    if k + 1 < raw.count {
        // with sound of its own, up to 1 s: CTC can mark a long word with one 80 ms frame
        // (a place name 728.48-728.56, spoken to ~729.3; the loudness fit trims any silence)
        if heard(outRows[k][0], outRows[k + 1][0]) { next = outRows[k + 1][0]; cap = 1.0 } else { next = raw[k + 1][0] }
    }
    var end = max(e, min(next, e + cap))
    if cap > 0.4 {   // but only while the sound goes on: stop at the first quiet frame (a breath after
        var g = Int((e * 100).rounded())   // a pause is not the word: "nature." ran on to 1.3 s),
        let g0 = g                         // after skipping up to 0.16 s of quiet (CTC can mark a word early)
        while g < db.count && g < g0 + 16 && db[g] <= thr { g += 1 }
        while g < db.count && Double(g) / 100 < end && db[g] > thr { g += 1 }
        end = max(e, min(end, max(e + 0.4, Double(g) / 100)))
    }
    outRows[k][1] = end
}
note("ctcalign: \(aligned)/\(words.count) words placed (\(fillersKept) fillers at Parakeet's times), \(bounds.count - 1) pieces, \(String(format: "%.1f", Double(audio.count) / 16000)) s of audio")
let json = try! JSONSerialization.data(withJSONObject: outRows.map { $0.map { (($0 * 1000).rounded() / 1000) as NSNumber } })
FileHandle.standardOutput.write(json)
