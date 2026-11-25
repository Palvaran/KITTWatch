import Foundation

/// Text normalisation shared by search, hazard triggers, and the intent parser.
/// Everything here is deterministic and cheap: it runs on every turn on the watch.
enum Text {
    static let stopwords: Set<String> = [
        "a", "an", "the", "we", "our", "us", "i", "my", "me", "you", "your", "should", "do", "does", "did",
        "is", "are", "was", "be", "been", "am", "to", "for", "of", "how", "what", "need",
        "have", "has", "had", "it", "its", "in", "on", "at", "and", "or", "if", "can", "could", "would",
        "will", "there", "this", "that", "with", "about", "from", "so", "then", "when", "any", "some",
        "just", "get", "got", "im", "were", "they", "them", "as", "by", "up", "out", "after", "during",
        "like", "please", "tell", "know", "want", "think", "he", "she", "him", "his", "her", "hers",
    ]

    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "-", with: " ")
        let kept = lowered.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "." || $0 == "'" ? Character($0) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ normalized: String) -> [String] {
        normalized.split(separator: " ")
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".'")) }
            .filter { !$0.isEmpty }
    }

    /// Whole-word phrase containment on normalized text.
    static func containsPhrase(_ haystack: String, _ phrase: String) -> Bool {
        (" " + haystack + " ").contains(" " + phrase + " ")
    }

    /// Light suffix stripping so "boiling", "boiled" and "boil" meet. Not linguistics:
    /// the same function is applied to the index and the query, which is all that matters.
    static func stem(_ word: String) -> String {
        var w = word.replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "'", with: "")
        guard w.count > 3 else { return w }
        if w.hasSuffix("ies"), w.count > 4 {
            w = String(w.dropLast(3)) + "y"
        } else {
            for suffix in ["ing", "ed", "es", "s"] where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
                if suffix == "s" && w.hasSuffix("ss") { break }
                w = String(w.dropLast(suffix.count))
                break
            }
        }
        if w.count > 3, w.hasSuffix("e") { w.removeLast() }
        // "stopp" -> "stop", "runn" -> "run"
        if w.count > 3, let last = w.last, w.dropLast().last == last, !"aeioulsz".contains(last) { w.removeLast() }
        return w
    }

    /// Stemmed content words of a sentence, stopwords removed, order kept.
    static func contentStems(_ text: String) -> [String] {
        tokens(normalize(text)).filter { !stopwords.contains($0) }.map(stem)
    }

    /// All stems, stopwords included (hazard triggers may need words like "out").
    static func allStems(_ text: String) -> Set<String> {
        Set(tokens(normalize(text)).map(stem))
    }

    // MARK: Sentences, negation, pointers

    /// Sentences of a message, each marked as a question or not. Decimals ("1.5") do not
    /// split, because a terminator only ends a sentence when a space or the end follows.
    static func sentences(_ raw: String) -> [(text: String, isQuestion: Bool)] {
        var out: [(String, Bool)] = []
        var current = ""
        let chars = Array(raw)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next == " " || next == "\n" {
                    out.append((current, ch == "?"))
                    current = ""
                }
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append((current, false)) }
        return out.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static let negators: Set<String> = [
        "not", "no", "never", "nothing", "none", "nobody", "neither", "nor", "without", "cannot",
        "dont", "wont", "cant", "didnt", "doesnt", "isnt", "wasnt", "arent", "werent", "hasnt", "havent",
        "hadnt", "wouldnt", "shouldnt", "couldnt",
    ]

    static func isNegator(_ token: String) -> Bool {
        negators.contains(token) || token.hasSuffix("n't")
    }

    /// Stems of a message, with words in `negatable` removed where a statement negates
    /// them: "I won't start it" drops "start", "nothing leaked" drops "leaked". A negator
    /// reaches the next three words of its clause; clauses end at , ; : and "but".
    /// Questions are left alone ("can't I run it inside?" still proposes running it).
    /// Returns the stems kept and the negatable stems that were dropped.
    static func stemsHonouringNegation(_ raw: String, negatable: Set<String>) -> (kept: Set<String>, negated: Set<String>) {
        var kept = Set<String>(), negated = Set<String>()
        for sentence in sentences(raw) {
            let clauses = sentence.text
                .replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: ":", with: ",")
                .components(separatedBy: ",")
                .flatMap { $0.components(separatedBy: " but ") }
            for clause in clauses {
                let tokens = Text.tokens(normalize(clause))
                var dropped = Set<Int>()
                if !sentence.isQuestion {
                    for (i, t) in tokens.enumerated() where isNegator(t) {
                        for j in (i + 1)..<min(i + 4, tokens.count) where negatable.contains(stem(tokens[j])) {
                            dropped.insert(j)
                        }
                    }
                }
                for (i, t) in tokens.enumerated() {
                    if dropped.contains(i) { negated.insert(stem(t)) } else { kept.insert(stem(t)) }
                }
            }
        }
        return (kept, negated)
    }

    static let pointerWords: Set<String> = ["it", "that", "this", "those", "these", "they", "them", "there"]

    /// A pointer word, contractions included ("it's", "that'll", "they're").
    static func isPointer(_ token: String) -> Bool {
        let base = token.split(separator: "'").first.map(String.init) ?? token
        return pointerWords.contains(base)
    }

    /// True when the message's first sentence has a pointer word, so the pointer can only
    /// refer to something said before this message. "The dryer is in the basement. Can I
    /// run it tonight?" refers to the dryer, not to the last message.
    static func refersToPreviousMessage(_ raw: String) -> Bool {
        guard let first = sentences(raw).first else { return false }
        return tokens(normalize(first.text)).contains(where: isPointer)
    }

    static let determiners: Set<String> = ["the", "a", "an", "our", "my", "your", "his", "her", "their", "its"]

    /// One clause of a message. Sentences split at . ! ?, clauses at , ; : and "but", and an
    /// embedded "whether ..." or "if ..." is a clause of its own ("May I ask | whether it's
    /// running?"). `group` counts the "but"s before the clause in its sentence.
    struct Clause {
        var tokens: [String]
        var isQuestion: Bool
        var sentence: Int
        var group: Int
        /// A question the user answers in the next sentence: "Is it idling? Yes, it is."
        /// true for yes, false for no.
        var answered: Bool? = nil
    }

    static func clauseList(_ raw: String) -> [Clause] {
        var out: [Clause] = []
        for (si, sentence) in sentences(raw).enumerated() {
            var group = 0
            let body = sentence.text.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: ":", with: ",")
            for piece in body.components(separatedBy: ",") {
                for (bi, part) in tokens(normalize(piece)).split(separator: "but", omittingEmptySubsequences: false).enumerated() {
                    if bi > 0 { group += 1 }
                    var current: [String] = []
                    for token in part {
                        if (token == "whether" || token == "if"), !current.isEmpty {
                            out.append(Clause(tokens: current, isQuestion: sentence.isQuestion, sentence: si, group: group))
                            current = []
                        }
                        current.append(token)
                    }
                    if !current.isEmpty {
                        out.append(Clause(tokens: current, isQuestion: sentence.isQuestion, sentence: si, group: group))
                    }
                }
            }
        }
        // "Is it idling? Yes, it is." The short answer settles the question before it.
        for si in Set(out.map(\.sentence)) {
            let question = out.indices.filter { out[$0].sentence == si }
            let reply = out.filter { $0.sentence == si + 1 }
            guard let q = question.first, out[q].isQuestion, !reply.isEmpty, !reply[0].isQuestion,
                  let polarity = shortAnswer(reply.flatMap(\.tokens)) else { continue }
            for i in question { out[i].answered = polarity }
        }
        return out
    }

    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "ya", "correct", "right", "sure", "definitely"]
    static let noWords: Set<String> = ["no", "nope", "nah", "isnt", "wasnt", "arent", "werent", "doesnt", "dont",
                                       "didnt", "not", "aint"]

    /// "Yes, it is." → true, "No, it isn't." → false, anything with more in it → nil.
    static func shortAnswer(_ tokens: [String]) -> Bool? {
        let filler: Set<String> = ["it", "its", "is", "was", "are", "were", "they", "theyre", "does", "do", "did",
                                   "i", "think", "so", "absolutely", "of", "course"]
        let words = tokens.map(plain)
        guard !words.isEmpty, words.allSatisfy({ yesWords.contains($0) || noWords.contains($0) || filler.contains($0) }),
              words.contains(where: { yesWords.contains($0) || noWords.contains($0) || ["is", "was", "are", "does"].contains($0) })
        else { return nil }
        return !words.contains(where: noWords.contains)
    }

    /// Clauses of a message as token lists, in order (see `clauseList`).
    static func clauses(_ raw: String) -> [(tokens: [String], isQuestion: Bool)] {
        clauseList(raw).map { ($0.tokens, $0.isQuestion) }
    }

    /// Indices of tokens a statement negates: words in `negatable` within three words after
    /// a negator. Questions negate nothing.
    static func negatedIndices(_ tokens: [String], isQuestion: Bool, negatable: Set<String>,
                               answered: Bool? = nil) -> Set<Int> {
        if answered == false { return Set(tokens.indices.filter { negatable.contains(stem(tokens[$0])) }) }
        guard !isQuestion else { return [] }
        var dropped = Set<Int>()
        for (i, t) in tokens.enumerated() where isNegator(t) {
            for j in (i + 1)..<min(i + 4, tokens.count) where negatable.contains(stem(tokens[j])) { dropped.insert(j) }
        }
        return dropped
    }

    /// True when a "the/our/my X" phrase names something, X being outside `vocabulary`.
    static func namesOtherThing(_ tokens: [String], vocabulary: Set<String>) -> Bool {
        for (k, token) in tokens.enumerated() where determiners.contains(token) {
            let following = tokens[(k + 1)..<min(k + 3, tokens.count)].map(stem)
            if let head = following.first, !vocabulary.contains(head), !following.contains(where: vocabulary.contains),
               !(tokens.indices.contains(k + 1) && isPointer(tokens[k + 1])) {
                return true
            }
        }
        return false
    }

    /// True when a pointer in the message can only mean something said before: the first
    /// clause with a pointer word has no earlier clause naming something else. So "Quick
    /// update. It's running downstairs" and "Would a LifeStraw fix that?" refer back, while
    /// "The dryer is in the basement. Can I run it tonight?" and "When the washer finishes,
    /// can I run it again?" refer to the dryer and the washer.
    static func pointerRefersBack(_ raw: String, vocabulary: Set<String>) -> Bool {
        let parts = clauses(raw).map(\.tokens)
        guard let p = parts.firstIndex(where: { $0.contains(where: isPointer) }) else { return false }
        return !parts[..<p].contains { namesOtherThing($0, vocabulary: vocabulary) }
    }

    /// Action words that belong to the hazard's device, clause by clause, not negated.
    /// A clause's actions belong to the device when the clause names one of `devices`
    /// ("the generator is running"), when its pointer means the device (the nearest earlier
    /// clause naming a thing names the device, or no earlier clause names anything and the
    /// pointer refers to the previous message), or when it names nothing else ("Running.",
    /// "We're planning to."). "The sump pump is running"
    /// belongs to the pump. Inside a clause that does not name the device, an action aimed
    /// at a named object ("run the dryer") is that object's.
    ///
    /// Only clauses of the given certainty count. By default that is plain statements and
    /// questions: "It might be running" and "No idea if it's running" describe no use.
    static func attributedActions(_ raw: String, actions: Set<String>, devices: Set<String>,
                                  vocabulary: Set<String>, negatable: Set<String>,
                                  certainty wanted: Certainty = .certain) -> Set<String> {
        let list = clauseList(raw)
        let all = list.map { (tokens: $0.tokens, isQuestion: $0.isQuestion) }
        let certainties = certainties(list, vocabulary: vocabulary)
        func namesDevice(_ t: [String]) -> Bool { t.contains { devices.contains(stem($0)) } }
        /// A pointer means the nearest thing named in an earlier clause of this message
        /// (the device, or something else), or failing that, the previous message.
        func pointerMeansDevice(_ c: Int) -> Bool {
            for k in stride(from: c - 1, through: 0, by: -1) {
                if namesDevice(all[k].tokens) { return true }
                if namesOtherThing(all[k].tokens, vocabulary: vocabulary) { return false }
            }
            return true
        }
        var out = Set<String>()
        for (c, clause) in all.enumerated() {
            let t = clause.tokens
            guard certainties[c] == wanted else { continue }
            let dropped = negatedIndices(t, isQuestion: clause.isQuestion, negatable: negatable, answered: list[c].answered)
            let namesDevice = namesDevice(t)
            let hasPointer = t.contains(where: isPointer)
            let belongs = namesDevice || (hasPointer && pointerMeansDevice(c)) || (!hasPointer && !namesOtherThing(t, vocabulary: vocabulary))
            guard belongs else { continue }
            for (i, token) in t.enumerated() where actions.contains(stem(token)) && !dropped.contains(i) {
                if !namesDevice {
                    var j = i + 1
                    if j < t.count, ["up", "out", "on"].contains(t[j]) { j += 1 }
                    if j < t.count, determiners.contains(t[j]) {
                        let object = t[(j + 1)..<min(j + 3, t.count)].map(stem)
                        if !object.contains(where: vocabulary.contains) { continue }
                    }
                }
                out.insert(stem(token))
            }
        }
        return out
    }

    /// "I don't know", "no idea", "not sure", "how can I tell?": the user cannot answer yet.
    static func saysUnknown(_ raw: String) -> Bool {
        let n = " " + tokens(normalize(raw)).map(plain).joined(separator: " ") + " "
        return unknownPhrases.contains { n.contains(" " + $0 + " ") }
    }

    private static func plain(_ token: String) -> String { token.replacingOccurrences(of: "'", with: "") }

    /// Saying you don't know yet. A clause with one of these is about not knowing, so a use
    /// word inside it ("No idea if it's running") is not a description of use.
    static let unknownPhrases = [
        "dont know", "do not know", "no idea", "not sure", "unsure", "no clue", "not certain",
        "cant tell", "cannot tell", "how can i tell", "how do i tell", "how would i know", "how do i know",
        "cant see", "cannot see", "cant hear", "cannot hear",
        "havent checked", "have not checked", "not checked", "havent looked", "have not looked", "not looked",
        "ill check", "will check", "let me check", "have to check", "need to check", "going to check", "gonna check",
        "is checking", "are checking", "checking now", "go check", "go look", "ill look", "let me look",
        "ill ask", "will ask", "find out"]

    /// Words that make a statement a possibility, not a fact: "It might be running", "Maybe
    /// we'll run it down there tonight", "It could be running". In a question they ask
    /// permission instead ("Could we run it in the garage?") and do not count.
    static let hedgeWords: Set<String> = ["maybe", "might", "may", "could", "perhaps", "possibly", "probably",
                                          "think", "thinking", "guess", "believe", "suppose", "considering"]

    /// Words that report a belief the user has since dropped: "I thought it was running.
    /// Turns out it's the dehumidifier." ("Thought about running it" is a possibility.)
    static let retractingWords: Set<String> = ["thought", "assumed", "figured"]

    /// Words that can stand beside a hedge in a clause that says nothing else ("I think",
    /// "I'm not sure", "probably not", "just a guess").
    static let hedgeFiller: Set<String> = ["i", "im", "we", "so", "yet", "just", "really", "pretty", "though",
                                           "anyway", "well", "oh", "um", "uh", "hmm", "honestly", "actually",
                                           "a", "not", "sure", "no", "idea", "dont", "do", "know", "unsure",
                                           "clue", "certain", "but", "kind", "sort", "of"]

    /// Who can propose doing something. In a question with one of these as subject the
    /// user asks to act ("Could I start it down there?"); with the thing as subject the
    /// user asks what is happening ("Could it already be running?").
    static let people: Set<String> = ["i", "we", "you", "me", "us"]

    /// Words that open a yes/no question.
    static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "am", "could", "can", "may", "might", "would", "will", "should", "does", "do",
        "did", "has", "have", "isnt", "arent", "wasnt", "couldnt", "cant", "wont", "wouldnt", "shouldnt",
        "doesnt", "dont", "didnt"]

    /// A plain statement or proposal; a possibility the user raises ("it might be running",
    /// "not sure"); a question about what is happening ("is it running?", "whether it's
    /// running"); or a belief the user has dropped or corrected.
    enum Certainty { case certain, possible, asked, retracted }

    /// A statement, a possibility or a dropped belief.
    ///   - Saying you don't know ("not sure", "haven't checked"), a hedged statement ("it
    ///     might be running") or "whether ..." is a possibility.
    ///   - "if ..." is a possibility unless a person is its subject ("if we run it there").
    ///   - A yes/no question about what the thing is doing now is a possibility: "Could it
    ///     already be running down there?" (see `asksWhatIsHappening`). A question with a
    ///     person as subject, or about using the thing, proposes the action: "Could I start
    ///     it down there?", "Can a camp cooker go in the tent?".
    static func certainty(_ tokens: [String], isQuestion: Bool) -> Certainty {
        let words = tokens.map(plain)
        if saysUnknown(words.joined(separator: " ")) { return .possible }
        if words.first == "whether" { return .asked }
        if words.first == "if" {
            // "if it's running", "if the generator is running": asks about a state.
            // "if we run it there", "if my dad starts the generator": proposes an action.
            guard words.count > 1, !people.contains(words[1]) else { return .certain }
            if isPointer(tokens[1]) || words.dropFirst().prefix(4).contains(where: beForms.contains) { return .asked }
            return .certain
        }
        if isQuestion {
            return asksWhatIsHappening(words) ? .asked : .certain
        }
        if let i = words.firstIndex(where: retractingWords.contains) {
            return i + 1 < words.count && ["about", "of"].contains(words[i + 1]) ? .possible : .retracted
        }
        return words.contains(where: hedgeWords.contains) ? .possible : .certain
    }

    /// A yes/no question about the thing's present state: "Is it running?", "Could it
    /// already be running down there?", "Might the coals still be burning?". Not one about
    /// whether it can be used: "Can a camp cooker go in the tent?", "Is it safe to run it
    /// there?", "Could I start it after supper?".
    static func asksWhatIsHappening(_ words: [String]) -> Bool {
        guard let first = words.first, auxiliaries.contains(first), words.count > 1, !words.contains("to") else { return false }
        // "Could I be hearing the generator?" asks what is happening, whoever the subject.
        let progressive = words.indices.contains { i in
            words[i] == "be" && words[(i + 1)...].contains { $0.hasSuffix("ing") }
        }
        if progressive { return true }
        guard !people.contains(words[1]) else { return false }
        let now: Set<String> = ["already", "still", "currently", "now"]
        return beForms.contains(first) || words.contains(where: now.contains)
    }

    static let beForms: Set<String> = ["is", "are", "was", "were", "am", "isnt", "arent", "wasnt", "werent"]

    /// A clause that is only a hedge: "I think", "probably", "I'm not sure".
    static func isBareHedge(_ tokens: [String]) -> Bool {
        let words = tokens.map(plain)
        let hedged = words.contains(where: hedgeWords.contains) || saysUnknown(words.joined(separator: " "))
        return hedged && words.allSatisfy { hedgeWords.contains($0) || hedgeFiller.contains($0) }
    }

    /// Each clause's certainty. A bare hedge covers the clauses beside it up to a "but", so
    /// a comma changes nothing: "The generator is idling, I think." is as uncertain as "The
    /// generator is idling I think." "I think the freezer stopped, but the generator is
    /// running." still says the generator is running. A question the user answers in the
    /// next sentence is a statement. With `vocabulary`, a correction that names something
    /// else retracts everything before it: "It's running. Sorry, I meant the dryer."
    static func certainties(_ list: [Clause], vocabulary: Set<String>? = nil) -> [Certainty] {
        var out = list.map { $0.answered != nil ? .certain : certainty($0.tokens, isQuestion: $0.isQuestion) }
        for hedge in list where !hedge.isQuestion && isBareHedge(hedge.tokens) {
            for j in list.indices where list[j].sentence == hedge.sentence && list[j].group == hedge.group && out[j] == .certain {
                out[j] = .possible
            }
        }
        if let vocabulary {
            for si in Set(list.map(\.sentence)).sorted() {
                let here = list.indices.filter { list[$0].sentence == si }
                guard let marker = here.first(where: { correctionMarker(list[$0].tokens) }),
                      here.contains(where: { namesOtherThing(list[$0].tokens, vocabulary: vocabulary) })
                else { continue }
                for j in 0..<marker { out[j] = .retracted }
            }
        }
        return out
    }

    /// "I meant", "my mistake", "scratch that", "wrong one": the user is correcting something
    /// said earlier in the message. It only counts beside something else named ("I meant the
    /// dryer"), and "sorry" alone is not one ("Sorry, the dryer is loud" corrects nothing).
    /// "I meant to start it" is not one either.
    static func correctionMarker(_ tokens: [String]) -> Bool {
        let words = tokens.map(plain)
        let n = " " + words.joined(separator: " ") + " "
        let phrases = ["correction", "scratch that", "my mistake", "my bad", "i misspoke", "wrong one",
                       "wrong device", "wrong thing", "wrong machine"]
        if phrases.contains(where: { n.contains(" " + $0 + " ") }) { return true }
        for (i, w) in words.enumerated() where (w == "meant" || w == "mean") && i > 0 && words[i - 1] == "i" {
            if i + 1 >= words.count || words[i + 1] != "to" { return true }
        }
        return false
    }

    /// Stems of the clauses of the given certainty, honouring negation (and a "no" answer to
    /// a question in the same message).
    static func stems(_ list: [Clause], _ certainties: [Certainty], keeping wanted: Certainty,
                      negatable: Set<String>) -> (kept: Set<String>, negated: Set<String>) {
        var kept = Set<String>(), negated = Set<String>()
        for (c, clause) in list.enumerated() where certainties[c] == wanted {
            let dropped = negatedIndices(clause.tokens, isQuestion: clause.isQuestion, negatable: negatable,
                                         answered: clause.answered)
            for (i, t) in clause.tokens.enumerated() {
                if dropped.contains(i) { negated.insert(stem(t)) } else { kept.insert(stem(t)) }
            }
        }
        return (kept, negated)
    }
}
