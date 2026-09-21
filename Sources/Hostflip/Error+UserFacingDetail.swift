import Foundation
import HostflipXPC

extension Error {
    /// The detail interpolated into user-facing failure copy. `String(describing:)` prints
    /// a Cocoa error as its domain/code/userInfo dump, although the error already carries a
    /// localized sentence. Everything else keeps its description: hostflip's own error
    /// enums have nothing better than the case name, and a DecodingError's description
    /// locates the fault where its localized sentence only says "wrong format".
    var userFacingDetail: String {
        if let channelError = self as? DaemonChannelError { return channelError.userMessage }
        if self is CocoaError { return localizedDescription }
        return String(describing: self)
    }
}
