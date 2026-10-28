// Verify exact archive bytes against the public key embedded in the app.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let publicBytes = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[3]) else {
    fatalError("usage: verify-release-signature.swift PUBLIC_KEY FILE SIGNATURE")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
let bytes = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: bytes) else {
    fputs("EdDSA signature does not match archive/public key\n", stderr)
    exit(1)
}
print("EdDSA archive signature verified against configured public key")
