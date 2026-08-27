//
//  AddMode.swift
//  VolcengineTLSProducer
//
//  Worker A — Swift public value model.
//

import Foundation

/// Admission mode for `Producer.add(_:mode:)`.
public enum AddMode: Equatable, Sendable {

    /// Enters the normal batching window (sealed when batch size/linger
    /// thresholds are reached).
    case normal

    /// Seals the current batch and wakes the sender immediately after this
    /// log is admitted. Still asynchronous: `add` does not wait for the
    /// network, an ACK, or server-side acceptance.
    case immediate
}
