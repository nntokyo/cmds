import CmdsCore
import Foundation

/// The rows above a terminal pane's screen (docs/internals/sync-protocol.md "Scrollback"): `requestScrollback` answered
/// now or once output lets the screen and the rows be read together, and for phones with
/// `SyncFeature.scrollbackStream` the rows that leave the screen with every screen update (`HistoryMark`).
extension SyncServer {
    /// `requestScrollback`: a full `screen` of the pane under a new seq, then the rows above it with that seq
    /// (docs/internals/sync-protocol.md "Scrollback"), now or as soon as possible (`answerScrollback`). A streaming
    /// phone gets the rows that leave the screen from then on with its screen updates (`historyUpdate`).
    func sendScrollback(_ request: ClientMessage.RequestScrollback, to client: Client) {
        let paneID = request.paneID
        guard let pane = AppController.shared.pane(id: paneID) else {
            return sendPaneNotFound(paneID, to: client)
        }
        guard pane.kind == .terminal, client.subscribed.contains(paneID) else {
            return sendError(.badRequest, "not a subscribed terminal pane: \(paneID.prefix(64))", to: client)
        }
        // One request waits per pane; a newer one replaces it. Streaming phones do not ask again by themselves.
        client.pendingScrollback[paneID] = SyncScrollback.clampedLines(request.lines)
        answerScrollback(paneID: paneID, to: client)
    }

    /// Answers the pane's waiting `requestScrollback` unless the previous read was less than `scrollbackInterval`
    /// ago, or output kept moving the viewport during every attempt; it then keeps waiting for `screenTick`.
    func answerScrollback(paneID: String, to client: Client, now: Date = Date()) {
        guard let maxRows = client.pendingScrollback[paneID] else { return }
        if let last = client.scrollbackSentAt[paneID], now.timeIntervalSince(last) < Self.scrollbackInterval { return }
        client.scrollbackSentAt[paneID] = now
        do {
            // The rows must end right above the screen: read again while output moves the viewport meanwhile.
            var answer: (screen: ScreenSnapshot, rows: [String], bar: TerminalScrollbar?)?
            for _ in 0..<Self.scrollbackAttempts {
                let bar = try AppController.shared.scrollbar(paneID: paneID)
                guard let screen = snapshot(paneID: paneID) else {
                    client.pendingScrollback[paneID] = nil
                    return sendPaneNotFound(paneID, to: client)
                }
                guard let rows = try AppController.shared.historyRows(paneID: paneID, maxRows: maxRows),
                      try AppController.shared.scrollbar(paneID: paneID) == bar else { continue }
                answer = (screen, rows.map(Self.trimmed), bar)
                break
            }
            // Output kept moving the history: no answer yet rather than an empty one, which would clear the phone's
            // rows; `screenTick` tries again.
            guard let answer else { return }
            client.pendingScrollback[paneID] = nil
            let full = client.streamer.full(paneID: paneID, snapshot: answer.screen.for(client))
            send(.screen(full), to: client)
            send(.scrollback(.init(paneID: paneID, seq: full.seq, lines: answer.rows)), to: client)
            if client.streamsHistory, let bar = answer.bar {
                client.historyMarks[paneID] = HistoryMark(bar: bar, cols: answer.screen.cols, rows: answer.rows)
            }
            // This screen may be newer than the last tick's; the next tick compares the client's copy with the
            // current one even if the pane looks unchanged to it (e.g. the screen went back to what the tick saw).
            client.pendingScreens.insert(paneID)
        } catch {
            client.pendingScrollback[paneID] = nil
            sendError(for: error, to: client)
        }
    }

    /// Answers the waiting `requestScrollback`s that can be answered now (`screenTick`); drops those of panes that
    /// are gone, no longer terminals or no longer subscribed.
    func answerWaitingScrollbacks(now: Date) {
        for client in clients.values where client.authenticated && !client.pendingScrollback.isEmpty {
            for paneID in Array(client.pendingScrollback.keys) {
                let terminal = AppController.shared.pane(id: paneID)?.kind == .terminal
                guard terminal, client.subscribed.contains(paneID) else {
                    client.pendingScrollback[paneID] = nil
                    continue
                }
                answerScrollback(paneID: paneID, to: client, now: now)
            }
        }
    }

    /// Panes a streaming phone has rows above the screen of (`Client.historyMarks`).
    var markedPanes: Set<String> {
        clients.values.reduce(into: Set<String>()) { if $1.authenticated { $0.formUnion($1.historyMarks.keys) } }
    }

    /// The pane's next `screen` / `screenDiff` for this client, if its screen changed. A streaming phone with rows
    /// above it gets the rows that left the screen with it (or `historyReset`), also when only those changed, in an
    /// unchanged full screen. `bar`: the viewport while `snapshot` was read, nil when it moved meanwhile.
    func sendUpdate(paneID: String, snapshot: ScreenSnapshot, bar: TerminalScrollbar?, to client: Client) {
        let snapshot = snapshot.for(client)
        let update = client.streamer.update(paneID: paneID, snapshot: snapshot)
        guard let mark = client.historyMarks[paneID] else {
            if let update { send(update, to: client) }
            return
        }
        if update == nil, bar == nil || bar == mark.bar { return }
        let history = historyUpdate(paneID: paneID, screen: snapshot, bar: bar, for: client)
        let message: ServerMessage
        switch (update, history) {
        case (let update?, .unchanged): message = update
        case (nil, .unchanged): return
        default: message = update ?? .screen(client.streamer.full(paneID: paneID, snapshot: snapshot))
        }
        switch history {
        case .unchanged: send(message, to: client)
        case .scrolledOff(let rows): send(message.withHistory(scrolledOff: rows, reset: false), to: client)
        case .reset: send(message.withHistory(scrolledOff: nil, reset: true), to: client)
        }
    }

    /// The rows of the pane that left the top of the screen since the client's `HistoryMark`, read by screen row
    /// without moving the viewport, and the mark moved to `bar`; `.reset` (mark dropped) when the rows above the
    /// screen no longer continue the phone's; `.unchanged` while `bar` is unknown or moves (a later update catches up).
    func historyUpdate(paneID: String, screen: ScreenSnapshot, bar: TerminalScrollbar?,
                       for client: Client) -> HistoryUpdate {
        guard var mark = client.historyMarks[paneID] else { return .unchanged }
        let update = mark.update(rows: screen.rows, cols: screen.cols, bar: bar) { count in
            // While the viewport is still where the screen was read.
            guard scrollbar(paneID: paneID) == bar,
                  let read = try? AppController.shared.historyRows(paneID: paneID, maxRows: count), read.count == count,
                  scrollbar(paneID: paneID) == bar else { return nil }
            return read.map(Self.trimmed)
        }
        client.historyMarks[paneID] = update == .reset ? nil : mark
        return update
    }

    /// Where a pane's viewport is in its whole screen, or nil if unknown / not a terminal.
    func scrollbar(paneID: String) -> TerminalScrollbar? {
        try? AppController.shared.scrollbar(paneID: paneID)
    }
}

extension ScreenSnapshot {
    /// This screen as sent to `client`: without styles unless it draws them (`SyncFeature.styles`).
    func `for`(_ client: SyncServer.Client) -> ScreenSnapshot {
        client.drawsStyles ? self : withoutStyles
    }
}
