//
//  Meshtastic.swift
//  bitchat
//
//  Created by Anton Appel on 05/03/2026.
//
//  This file handles bidirectional conversion between BitChat messages and Meshtastic packets.
//
//  OUTBOUND (BitChat → Meshtastic):
//  1. Extract message payload from BitchatPacket
//  2. Convert to TAKPacket (ATAK format) 
//  3. Wrap in ToRadio protobuf with ATAK_PLUGIN portnum
//  4. Serialize and send to Meshtastic radio via BLE
//
//  INBOUND (Meshtastic → BitChat):
//  1. Receive FromRadio protobuf from Meshtastic radio
//  2. Extract TAKPacket from ATAK_PLUGIN payload
//  3. Extract message text/data from TAKPacket
//  4. Wrap in new BitchatPacket for local mesh
//

import BitLogger
import Foundation
import Combine
import CoreBluetooth
import MeshtasticProtobufs
import SwiftProtobuf


final class Meshtastic: NSObject {
    
    // MARK: - Constants
    
    
    static let meshtasticServiceCBUUID = CBUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
    static let meshtasticTORADIO_UUID = CBUUID(string: "F75C76D2-129E-4DAD-A1DD-7866124401E7")
    static let meshtasticFROMRADIO_UUID = CBUUID(string: "2C55E69E-4993-11ED-B878-0242AC120002")
    static let meshtasticFROMNUM_UUID = CBUUID(string: "ED9DA18C-A800-4F66-A670-AA7547E34453")
    static let meshtasticLOGRADIO_UUID = CBUUID(string: "5a3d6e49-06e6-4423-9944-e9de8cdf9547")
    
    // MARK: - Protobuf encoding
    // Convert BitChat message payload to ATAK protocol
    public static func toAttakProtocol(_ messagePayload: Data) -> TAKPacket? {
        // Build a TAKPacket from BitChat message payload.
        // If the data is UTF-8 text, use GeoChat.message; otherwise, place raw bytes into `detail`.
        var tak = TAKPacket()
        
        // Try to interpret as text message first
        if let text = String(data: messagePayload, encoding: .utf8), !text.isEmpty {
            var chat = GeoChat()
            chat.message = text
            tak.chat = chat
            SecureLogger.debug("📡 Created TAKPacket with text message: '\(text.prefix(50))...'", category: .session)
        } else {
            // Not text - send as raw detail bytes
            tak.detail = messagePayload
            SecureLogger.debug("📡 Created TAKPacket with \(messagePayload.count) bytes of binary data", category: .session)
        }
        return tak
    }
    
    public static func toMeshtastic(_ messagePayload: Data) -> ToRadio? {
        // Convert BitChat message payload -> TAKPacket -> ToRadio (MeshPacket with ATAK_PLUGIN port)
        guard let tak = toAttakProtocol(messagePayload) else {
            SecureLogger.error("Meshtastic: failed to convert message to TAKPacket", category: .session)
            return nil
        }
        guard let takBytes = try? tak.serializedData() else {
            SecureLogger.error("Meshtastic: failed to serialize TAKPacket", category: .session)
            return nil
        }
        
        // Build ToRadio via JSON to avoid tight coupling to generated nested message names
        // JSON expects base64 for bytes fields
        // "to": 4294967295 is the broadcast address (^0 in uint32)
        let b64 = takBytes.base64EncodedString()
        let json = """
        {"packet":{"to":4294967295,"wantAck":false,"decoded":{"portnum":"ATAK_PLUGIN","payload":"\(b64)"}}}
        """
        
        do {
            let toRadio = try ToRadio(jsonString: json)
            SecureLogger.debug("📡 Created ToRadio packet with ATAK_PLUGIN payload (\(takBytes.count) bytes)", category: .session)
            return toRadio
        } catch {
            SecureLogger.error("Meshtastic: failed to build ToRadio from JSON: \(error)", category: .session)
            return nil
        }
    }
    
    public static func toMeshtasticData(_ messagePayload: Data) -> Data {
        // Serialize the ToRadio envelope for BLE write
        if let toRadio = toMeshtastic(messagePayload) {
            if let bin = try? toRadio.serializedData() {
                SecureLogger.debug("📡 Serialized ToRadio to \(bin.count) bytes for BLE write", category: .session)
                return bin
            } else {
                SecureLogger.error("Meshtastic: failed to serialize ToRadio", category: .session)
            }
        } else {
            SecureLogger.error("Meshtastic: toMeshtastic returned nil", category: .session)
        }
        return Data()
    }
    
    public static func toBitchat(_ radioData: Data) -> Data? {
        // Unpack Meshtastic FromRadio envelope and extract the message payload
        do {
            let fromRadio = try FromRadio(serializedBytes: radioData)
            
            // Check if this is a packet with decoded data
            // Swift Protobuf uses payloadVariant enum instead of hasPacket
            guard case .packet(let meshPacket) = fromRadio.payloadVariant else {
                SecureLogger.debug("📡 FromRadio has no packet field", category: .session)
                return nil
            }
            
            // Check if it has decoded data with ATAK_PLUGIN portnum
            // Swift Protobuf uses payloadVariant enum instead of hasDecoded
            guard case .decoded(let data) = meshPacket.payloadVariant else {
                SecureLogger.debug("📡 FromRadio packet has no decoded data", category: .session)
                return nil
            }
            
            // Log the portnum for debugging
            SecureLogger.debug("📡 FromRadio portnum: \(data.portnum)", category: .session)
            
            // Check if this is an ATAK packet (portnum 72 = ATAK_PLUGIN)
            if data.portnum.rawValue == 72 || data.portnum == .atakPlugin {
                let atakPayload = data.payload
                SecureLogger.info("📡 Received ATAK packet (\(atakPayload.count) bytes)", category: .session)
                
                // Try to parse as TAKPacket
                if let tak = try? TAKPacket(serializedBytes: atakPayload) {
                    // Extract the actual message content from TAKPacket
                    switch tak.payloadVariant {
                    case .detail(let bytes):
                        SecureLogger.debug("📡 Extracted detail bytes (\(bytes.count) bytes)", category: .session)
                        return bytes
                    case .chat(let chat):
                        SecureLogger.debug("📡 Extracted chat message: '\(chat.message.prefix(50))...'", category: .session)
                        return chat.message.data(using: .utf8)
                    case .pli:
                        SecureLogger.debug("📡 Received PLI (position) packet", category: .session)
                        // Could convert PLI to a text status message if needed
                        return nil
                    case .none:
                        SecureLogger.warning("📡 TAKPacket has no payload variant", category: .session)
                        return nil
                    }
                } else {
                    SecureLogger.warning("📡 Could not parse ATAK payload as TAKPacket", category: .session)
                    // Return raw ATAK payload as fallback
                    return atakPayload
                }
            } else {
                SecureLogger.debug("📡 Ignoring non-ATAK packet (portnum: \(data.portnum))", category: .session)
                return nil
            }
        } catch {
            SecureLogger.warning("📡 Could not parse as FromRadio: \(error)", category: .session)
            
            // Fallback: Try to parse directly as TAKPacket (for debugging/testing)
            if let tak = try? TAKPacket(serializedBytes: radioData) {
                switch tak.payloadVariant {
                case .detail(let bytes):
                    return bytes
                case .chat(let chat):
                    return chat.message.data(using: .utf8)
                case .pli, .none:
                    return nil
                }
            }
            
            return nil
        }
    }
    
    public static func isAtak(_ takData: Data) -> Bool {
        // Basic sniffing to avoid always-true result. Adjust once exact envelope is known.
        if takData.isEmpty { return false }

        // Try to parse as TAKPacket protobuf first
        if (try? TAKPacket(serializedBytes: takData)) != nil { return true }

        // Or check if it's UTF-8 JSON that can initialize TAKPacket
        if let json = String(data: takData, encoding: .utf8),
           (try? TAKPacket(jsonString: json)) != nil {
            return true
        }

        return false
    }
    
    public static func isAtak(_ radioData: ToRadio) -> Bool {
        // Determine if the ToRadio message carries an ATAK payload.
        // Strategy: JSON-encode and inspect for portnum == ATAK_PLUGIN (enum) or numeric 72.
        if let jsonData = try? radioData.jsonUTF8Data(),
           let json = String(data: jsonData, encoding: .utf8) {
            if json.contains("\"portnum\":\"ATAK_PLUGIN\"") || json.contains("\"portnum\":72") {
                return true
            }
        }

        // Fallback: If for some reason the ToRadio directly embeds TAK bytes (unlikely),
        // reuse the Data-based checker. This will be false for normal ToRadio envelopes.
        if let bin = try? radioData.serializedData(), Meshtastic.isAtak(bin) {
            return true
        }

        return false
    }
}

