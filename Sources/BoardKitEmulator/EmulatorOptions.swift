import Foundation
import BoardKitTestSupport
import PegasusAdapter
import MillenniumAdapter
import CertaboAdapter
import ChessUpAdapter

/// Hand-rolled CLI options (swift-argument-parser is intentionally not a
/// dependency — BoardKit carries no third-party packages beyond ChessCore).
///
/// ```
/// boardkit-emulator <squareoff|chessnut>
///     [--pgn <file>]            play this PGN's main line (default: seeded random game)
///     [--seed <n>]              chaos + random-game seed (default 0xF1A7)
///     [--chaos <profile>]       clean | casual | clumsy | hostile (default casual)
///     [--think-ms <n>]          pause before playing own scripted moves (default 2000)
///     [--human-ms <n>]          pause before executing an LED-dictated move (default 1200)
///     [--capture <out.replay>]  write a ReplayScript-format traffic capture
///     [--name <s>]              override the advertised local name
///     [--battery <n>]           Chessnut battery percent (default 88)
///     [--notify-gap-ms <n>]     pacing between BLE notification chunks (default 15)
///     [--dry-run [plies]]       no BLE: play up to N plies (default 12) printing frames, then exit
///     [--push-state-every <n>]  [test knob] emit an unsolicited board-state frame after every
///                               n-th executed move (divergence-detection aid; default OFF —
///                               real boards do not push unsolicited state)
/// ```
public struct EmulatorOptions: Sendable, Equatable {

    public enum BoardKind: String, Sendable {
        case squareoff
        case chessnut
        case pegasus
        case millennium
        case certabo
        case chessup
    }

    public var boardKind: BoardKind
    public var pgnPath: String?
    /// Chaos/game RNG seed. Defaults to a fresh random value per launch so
    /// repeated sessions play different games; pass --seed to reproduce a
    /// session exactly (the capture header records the resolved value).
    public var seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    public var chaosProfile: ChaosProfile = .casual
    public var thinkMs: Int = 2_000
    public var humanMs: Int = 1_200
    public var capturePath: String?
    public var advertisedName: String?
    public var batteryPercent: Int = 88
    public var notifyGapMs: Int = 15
    public var dryRun: Bool = false
    public var dryRunPlies: Int = 12
    /// After every n-th executed move the personality emits an UNSOLICITED board-state frame
    /// (occupancySnapshot for SquareOff, identitySnapshot for Chessnut).
    ///
    /// Default is `nil` (OFF). Documented as a **divergence-detection test knob**: it lets the
    /// host's occupancy-mismatch machinery notice app/board drift without a manual sync request.
    /// Left off by default because real boards do not push unsolicited state — enabling it changes
    /// the protocol in a way the host adapter does not expect from hardware.
    public var pushStateEvery: Int? = nil

    public static let usage = """
    usage: boardkit-emulator <squareoff|chessnut|pegasus|millennium|certabo|chessup> [options]
      --pgn <file>            play this PGN's main line (default: seeded random game)
      --seed <n>              chaos + random-game seed (default 0xF1A7)
      --chaos <profile>       clean | casual | clumsy | hostile (default casual)
      --think-ms <n>          pause before playing own scripted moves (default 2000)
      --human-ms <n>          pause before executing an LED-dictated move (default 1200)
      --capture <out.replay>  write a ReplayScript-format traffic capture
      --name <s>              override the advertised local name
      --battery <n>           Chessnut battery percent (default 88)
      --notify-gap-ms <n>     pacing between BLE notification chunks (default 15)
      --dry-run [plies]       no BLE: play up to N plies (default 12) printing frames, then exit
      --push-state-every <n>  [test knob] emit an unsolicited board-state frame after every n-th
                              executed move; lets the host's mismatch machinery catch drift without
                              a manual sync (default OFF — real boards do not push unsolicited state)
    """

    /// Usage / parse failure with a message suitable for stderr.
    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
        init(_ message: String) { self.message = message }
    }

    /// Parse `arguments` (argv without the executable path).
    public static func parse(_ arguments: [String]) -> Result<EmulatorOptions, UsageError> {
        do {
            return .success(try parseOrThrow(arguments))
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(UsageError("\(error)"))
        }
    }

    private static func parseOrThrow(_ arguments: [String]) throws -> EmulatorOptions {
        guard let first = arguments.first else {
            throw UsageError("missing board kind\n\(usage)")
        }
        guard let kind = BoardKind(rawValue: first.lowercased()) else {
            throw UsageError("unknown board kind '\(first)' (expected squareoff | chessnut | pegasus | millennium | certabo | chessup)\n\(usage)")
        }
        var options = EmulatorOptions(boardKind: kind)

        var index = 1
        func stringValue(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw UsageError("\(flag) requires a value\n\(usage)")
            }
            return arguments[index]
        }
        func intValue(_ flag: String) throws -> Int {
            let raw = try stringValue(flag)
            guard let value = Int(raw) else {
                throw UsageError("\(flag) requires an integer, got '\(raw)'")
            }
            return value
        }

        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--pgn":
                options.pgnPath = try stringValue(flag)
            case "--seed":
                let raw = try stringValue(flag)
                guard let seed = UInt64(raw) else {
                    throw UsageError("--seed requires an unsigned integer, got '\(raw)'")
                }
                options.seed = seed
            case "--chaos":
                let raw = try stringValue(flag)
                guard let profile = ChaosProfile.named(raw) else {
                    throw UsageError("unknown chaos profile '\(raw)' (clean | casual | clumsy | hostile)")
                }
                options.chaosProfile = profile
            case "--think-ms":
                options.thinkMs = try intValue(flag)
            case "--human-ms":
                options.humanMs = try intValue(flag)
            case "--capture":
                options.capturePath = try stringValue(flag)
            case "--name":
                options.advertisedName = try stringValue(flag)
            case "--battery":
                options.batteryPercent = try intValue(flag)
            case "--notify-gap-ms":
                options.notifyGapMs = try intValue(flag)
            case "--dry-run":
                options.dryRun = true
                if index + 1 < arguments.count, let plies = Int(arguments[index + 1]) {
                    options.dryRunPlies = plies
                    index += 1
                }
            case "--push-state-every":
                options.pushStateEvery = try intValue(flag)
            case "--help", "-h":
                throw UsageError(usage)
            default:
                throw UsageError("unknown option '\(flag)'\n\(usage)")
            }
            index += 1
        }
        return options
    }

    /// Build the personality for the selected board kind.
    public func makePersonality() -> any BoardPersonality {
        switch boardKind {
        case .squareoff:
            return SquareOffPersonality(advertisedName: advertisedName ?? "Squareoff Pro")
        case .chessnut:
            return ChessnutPersonality(advertisedName: advertisedName ?? "Chessnut Air",
                                       batteryPercent: batteryPercent)
        case .pegasus:
            return PegasusPersonality(advertisedName: advertisedName ?? PegasusGATT.factoryNamePrefix)
        case .millennium:
            return MillenniumPersonality(advertisedName: advertisedName ?? MillenniumGATT.advertisedName)
        case .certabo:
            return CertaboPersonality(advertisedName: advertisedName ?? "Certabo")
        case .chessup:
            return ChessUpPersonality(advertisedName: advertisedName ?? "ChessUp")
        }
    }
}
