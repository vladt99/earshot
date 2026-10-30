import Foundation

/// What Earshot knows about a meeting besides its audio: the room, who is in it, and what happened when.
/// Filled live by `MeetObserver` (Google Meet's accessibility tree) and the calendar, saved with the meeting,
/// and used to count and name speakers. All times are seconds since the session's start (the audio timeline).
struct MeetingContext: Codable, Sendable, Hashable {
    var platform: String?
    /// e.g. "abc-defg-hij" for Google Meet.
    var meetingCode: String?
    var url: String?
    var title: String?
    var calendar: CalendarInfo?
    /// ISO 639-1 code of the platform's caption language (Meet's "Captions and translation" setting).
    var captionLanguage: String?
    var participants: [MeetingParticipant] = []
    var events: [MeetingEvent] = []
    var captions: [CaptionTurn] = []
    /// Intervals during which your own microphone was muted in the meeting app, as [start, end] pairs.
    var selfMuted: [[Double]] = []
    /// The meeting app showed its end screen ("You left the meeting").
    var ended = false

    /// People who can be heard on the others track: not you, not bots, not presentation tiles.
    var speakingParticipants: [MeetingParticipant] { participants.filter { !$0.isSelf && !$0.bot && !$0.presentation } }
}

struct MeetingParticipant: Codable, Sendable, Hashable {
    var name: String
    var email: String?
    /// Meet marks guests from outside the organisation ("outside Acme").
    var external = false
    /// Other notetakers (Fathom, Fireflies, Otter, Read.ai, tl;dv, …).
    var bot = false
    var isSelf = false
    /// "Name (Presentation)" tiles.
    var presentation = false
    var joinedAt: Double?
    var leftAt: Double?
    /// "meet", "calendar" or both ("meet,calendar").
    var source = "meet"
}

struct MeetingEvent: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, Hashable {
        case joined, left, presentingStarted, presentingStopped, chat, muted, unmuted, selfMuted, selfUnmuted,
             handRaised, notetakerJoined, waiting, ended,
             reaction, screenShareStarted, screenShareStopped, joinedElsewhere, captionsOn, captionsOff
    }
    var t: Double
    var kind: Kind
    var who: String?
    var text: String?
}

/// One caption run as the platform showed it: who spoke, roughly when, and the platform's own caption text
/// (used only to align and name speakers, never as transcript text).
struct CaptionTurn: Codable, Sendable, Hashable {
    var start: Double
    var end: Double
    var speaker: String
    var isSelf = false
    var text: String
}

struct CalendarInfo: Codable, Sendable, Hashable {
    var eventID: String?
    var title: String?
    var organizer: String?
    var notes: String?
    var start: Date?
    var end: Date?
    var attendees: [Attendee] = []
    /// Same for every occurrence of a recurring event, so meetings of one series can be grouped.
    var seriesID: String? = nil

    struct Attendee: Codable, Sendable, Hashable {
        var name: String?
        var email: String?
        /// "accepted", "declined", "tentative", "pending", "unknown".
        var status: String
    }
}
