//
//  Meshtastic.swift
//  bitchat
//
//  Created by Anton Appel on 05/03/2026.
//

import BitLogger
import Foundation
import Combine
import CoreBluetooth
import MeshtasticProtobufs
import SwiftProtobuf
import BitLogger


extension BLEService {
    
    // MARK: - Meshtastic constants
    static let meshtasticServiceCBUUID = CBUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
    static let meshtasticTORADIO_UUID = CBUUID(string: "F75C76D2-129E-4DAD-A1DD-7866124401E7")
    static let meshtasticFROMRADIO_UUID = CBUUID(string: "2C55E69E-4993-11ED-B878-0242AC120002")
    static let meshtasticFROMNUM_UUID = CBUUID(string: "ED9DA18C-A800-4F66-A670-AA7547E34453")
    static let meshtasticLOGRADIO_UUID = CBUUID(string: "5a3d6e49-06e6-4423-9944-e9de8cdf9547")
    
    // 30 minutes before cleaning un the peer
    static let meshtasticPeerInactivityTimeoutSeconds: Double = 1800.0
    
    // MARK: - Protobuf encoding && static methods
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
        if let bin = try? radioData.serializedData(), BLEService.isAtak(bin) {
            return true
        }

        return false
    }
    
    
    // MARK: - BLE Methods
    public func connectToMeshtastic(peripheral: CBPeripheral, service: CBService) {
        // pair the device
        peripheral.delegate = self
        SecureLogger.debug("✨ Connecting to a Meshtastic Radio")
        
        guard let characteristics = service.characteristics else { return }
        
        var foundToRadio: CBCharacteristic?
        var foundFromRadio: CBCharacteristic?
        var foundFromNum: CBCharacteristic?
        let peripheralID = peripheral.identifier.uuidString
    
        
        for characteristic in characteristics {
            let props = characteristic.properties
            SecureLogger.debug("🔍 Props from \(characteristic.uuid): \(props.rawValue)")

            switch characteristic.uuid {
            case BLEService.meshtasticTORADIO_UUID:
                foundToRadio = characteristic
                SecureLogger.debug("✅ Found TORADIO")

            case BLEService.meshtasticFROMRADIO_UUID:
                foundFromRadio = characteristic
                SecureLogger.debug("✅ Found FROMRADIO")
                
            case BLEService.meshtasticFROMNUM_UUID:
                foundFromNum = characteristic
                SecureLogger.debug("✅ Found FROMNUM")
                
            default:
                break
            }
        }
        
        guard let toRadio = foundToRadio, let fromRadio = foundFromRadio else {
            SecureLogger.error("❌ Missing mandatory characteristics")
            return
        }
        
        if var state = self.peripherals[peripheralID] {
            state.toRadioCharacteristic = toRadio
            state.fromRadioCharacteristic = fromRadio
            state.isConnected = true
            self.peripherals[peripheralID] = state
        } else {
            // Create new peripheral state if it doesn't exist
            let newState = BLEService.PeripheralState(
                peripheral: peripheral,
                characteristic: nil,
                peerID: nil,
                isConnecting: false,
                isConnected: true,
                lastConnectionAttempt: nil,
                assembler: NotificationStreamAssembler(),
                toRadioCharacteristic: toRadio,
                fromRadioCharacteristic: fromRadio
            )
            self.peripherals[peripheralID] = newState
        }
        
        
        // Notify UI immediately
        notifyUI {
            // Set the mtt device to connected
            if let index = self.meshtasticServices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier}) {
                self.meshtasticServices[index].connected = true
            }
        }

        SecureLogger.debug("✅ Stored Meshtastic characteristics for \(peripheral.name ?? "Unknown")", category: .session)
        
        // Meshtastic Handshake to connect to the radio
        let configId = UInt32.random(in: 1...UInt32.max)
        var toRadioPacket = ToRadio()
        toRadioPacket.wantConfigID = configId
        if let data = try? toRadioPacket.serializedData() {
            peripheral.writeValue(data, for: toRadio, type: .withResponse)
            SecureLogger.debug("📤 Sent want_config_id: \(configId)")
        }
        peripheral.readValue(for: fromRadio)
    
        // We can the finnaly subscribe to from num
        if let fromNum = foundFromNum {
            self.messageQueue.asyncAfter(deadline: .now() + 0.5) {
                peripheral.setNotifyValue(true, for: fromNum)
                SecureLogger.debug("🔔 Subscribed to FROMNUM")
            }
        }
        self.messageQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.sendAnnounce(forceSend: true)
            self?.flushDirectedSpool()
        }
        SecureLogger.info("✨ Meshtastic Handshake Complete for \(peripheral.name ?? "Unknown"), sending hellos", category: .session)
        
        sendHello(peripheral: peripheral, service: service)
    }
    
    private func getMyPeerInfo() -> PeerInfo {
        // Get our nickname
        let myNickname = self.myNickname
        
        return PeerInfo(
            peerID: self.myPeerID,
            nickname: myNickname,
            isConnected: true,
            noisePublicKey: nil,
            signingPublicKey: nil,
            isVerifiedNickname: true,  // We trust our own nickname
            lastSeen: Date(),
        )
    }

    public func handleMeshtasticPacket(chunk: Data, peripheral: CBPeripheral, state: PeripheralState) {
        // This is data from a Meshtastic radio
        SecureLogger.info("📡 Received \(chunk.count) bytes from Meshtastic radio: \(state.peripheral.name ?? "unknown")")
        
        // Try to extract the message payload from the Meshtastic FromRadio envelope
        if let messageData = BLEService.toBitchat(chunk) {
            SecureLogger.info("📡 Extracted \(messageData.count) bytes from Meshtastic packet")
            if let originalPacket = BinaryProtocol.decode(messageData) {
                switch MessageType(rawValue: originalPacket.type) {
                case .mttHello:
                    handleReceiveHello(packet: originalPacket, peripheral: peripheral, state: state)
                    return
                case .mttHelloBack:
                    handleReceiveHelloBack(packet: originalPacket, peripheral: peripheral)
                    return
                default:
                    break
                }
                
                // Process the packet locally (updates UI, stores in history, etc.)
                processNotificationPacket(originalPacket, from: peripheral, peripheralUUID: peripheral.identifier.uuidString)
                

                if let packetData = originalPacket.toBinaryData(padding: false) {
                    sendOnAllLinks(
                        packet: originalPacket,
                        data: packetData,
                        pad: false,
                        directedOnlyPeer: nil as PeerID?
                    )
                    SecureLogger.debug("📡 Forwarded Meshtastic message to Bitchat mesh network", category: .session)
                } else {
                    SecureLogger.error("❌ Could not serialize packet for forwarding", category: .session)
                }

            } else {
                SecureLogger.error("❌ Could not process packet from Meshtastic")
            }
        } else {
            SecureLogger.warning("📡 Could not extract message from Meshtastic data", category: .session)
        }
    }
    
    public func getDataFromMeshtastic(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let data = characteristic.value, !data.isEmpty else {
            return
        }
        
        // Parser le FromRadio protobuf
        do {
            let fromRadio = try FromRadio(serializedBytes: data)
            
            switch fromRadio.payloadVariant {
                
            case .packet(let meshPacket):
                // C'est un vrai packet mesh
                switch meshPacket.payloadVariant {
                    
                case .decoded(let decoded):
                    switch decoded.portnum {
                        
                    case .atakPlugin:
                        SecureLogger.info("🎯 ATAK packet received — \(decoded.payload.count) bytes")
                        bufferNotificationChunk(data, from: peripheral)
                        
                    case .textMessageApp:
                        SecureLogger.info("💬 Text message Meshtastic")
                        
                    case .positionApp:
                        SecureLogger.debug("📍 Position packet — ignoré")
                        
                    default:
                        SecureLogger.debug("📦 Portnum ignoré: \(decoded.portnum)")
                    }
                    
                case .encrypted:
                    // Packet chiffré non décodable (pas notre channel)
                    SecureLogger.debug("🔒 Encrypted packet — ignoré")
                    
                default:
                    break
                }
                
            case .myInfo(let info):
                SecureLogger.info("ℹ️ MyInfo reçu: nodeNum=\(info.myNodeNum)")
                
            case .nodeInfo(let node):
                SecureLogger.debug("👤 NodeInfo: \(node.user.longName)")
                
            default:
                SecureLogger.debug("📨 FromRadio payload ignoré: \(fromRadio.payloadVariant, default: "#ignored")")
            }
            
        } catch {
            SecureLogger.error("❌ Protobuf parse error: \(error)")
        }
    }
    
    // MARK: -- Meshtastic Hello and HelloBack
    
    public func sendHello(peripheral: CBPeripheral, service: CBService) {
        // Sends the meshtastic handshake for discovery and announcing oursevles
        // Here, just first phase
        // Protocol
        // 1. Us -> {.mttHello, bc,   [meshtasticRadioName, MyPeerInfo, other peers info]}
        // 2. Other <- {.mttHelloBack, myPeerID,   [meshtasticRadioName, TheirPeerInfo, other peers info]}
        
        var packetData = Data()
        let peripheralID = peripheral.identifier.uuidString
        guard let state = self.peripherals[peripheralID] else {
            SecureLogger.error("❌ Cannot find peripheral ID \(peripheralID)")
            return
        }
        
        guard let toRadio = state.toRadioCharacteristic else {
            SecureLogger.error("❌ Cannot find toRadio characteristic for \(peripheralID)")
            return
        }
        
        let helloID = UInt16.random(in: 0..<(2^16-1)).bigEndian
        packetData.append(contentsOf: withUnsafeBytes(of: helloID) { Array($0) })
        
        // Add meshtasticRadioName (length-prefixed string)
        let radioName = peripheral.name ?? "Unknown"
        appendLengthPrefixed(string: radioName, to: &packetData)
        
        // Count + 1 because we add our information at the beggining of the peer list
        let count = UInt16(peers.count + 1).bigEndian
        packetData.append(contentsOf: withUnsafeBytes(of: count) { Array($0) })
        
        packetData.append(serializePeer(getMyPeerInfo()))
        for (_, peer) in self.peers {
            packetData.append(serializePeer(peer))
        }
        
        // Create BitchatPacket with type .mttHello
        let bitchatPacket = BitchatPacket(
            type: MessageType.mttHello.rawValue,
            ttl: 7,
            senderID: self.myPeerID,
            payload: packetData,
            isRSR: false
        )
        
        guard let bitchatData = bitchatPacket.toBinaryData(padding: false) else {
            SecureLogger.error("❌ Failed to encode BitchatPacket for mttHello")
            return
        }
        
        // Convert BitchatPacket to Meshtastic ToRadio format
        let meshtasticData = BLEService.toMeshtasticData(bitchatData)
        
        guard !meshtasticData.isEmpty else {
            SecureLogger.error("❌ Cannot serialize data for meshtastic Hello packet")
            return
        }
        
        SecureLogger.debug("📤 Sending mttHello packet (\(bitchatData.count) bytes payload) via Meshtastic (radio: \(radioName))", category: .session)
        peripheral.writeValue(meshtasticData, for: toRadio, type: .withResponse)
    }
    
    
    public func sendHelloBack(peripheral: CBPeripheral, characteristic: CBCharacteristic, helloId: UInt16) {
        var packetData = Data()
        
        packetData.append(contentsOf: withUnsafeBytes(of: helloId) { Array($0) })
        
        // Add meshtasticRadioName (length-prefixed string)
        let radioName = peripheral.name ?? "Unknown"
        appendLengthPrefixed(string: radioName, to: &packetData)
        
        // Count + 1 because we add our information at the beggining of the peer list
        let count = UInt16(peers.count + 1).bigEndian
        packetData.append(contentsOf: withUnsafeBytes(of: count) { Array($0) })
        
        packetData.append(serializePeer(getMyPeerInfo()))
        for (_, peer) in self.peers {
            packetData.append(serializePeer(peer))
        }
        
        // Create BitchatPacket with type .mttHelloBack
        let bitchatPacket = BitchatPacket(
            type: MessageType.mttHelloBack.rawValue,
            ttl: 7,
            senderID: self.myPeerID,
            payload: packetData,
            isRSR: false,
        )
        
        guard let bitchatData = bitchatPacket.toBinaryData(padding: false) else {
            SecureLogger.error("❌ Failed to encode BitchatPacket for mttHelloBack")
            return
        }
        
        // Convert BitchatPacket to Meshtastic ToRadio format
        let meshtasticData = BLEService.toMeshtasticData(bitchatData)
        
        guard !meshtasticData.isEmpty else {
            SecureLogger.error("❌ Cannot serialize data for meshtastic HelloBack packet")
            return
        }
        
        SecureLogger.debug("📤 Sending mttHelloBack packet (\(bitchatData.count) bytes payload) via Meshtastic (radio: \(radioName))", category: .session)
        peripheral.writeValue(meshtasticData, for: characteristic, type: .withResponse)
    }
    
    
    public func handleReceiveHello(packet: BitchatPacket, peripheral: CBPeripheral, state: PeripheralState) {
        guard let toRadio = state.toRadioCharacteristic else {
            SecureLogger.error("❌ Cannot get to radio characteristic")
            return
        }
        
        // Deserialize the packet from the Hello protocole
        guard let packetContent = try? deserializePeers(from: packet.payload) else {
            SecureLogger.error("❌ Unable to deserialize HelloBack packet from \(peripheral.name ?? "Unknown")")
            return
        }
        
        SecureLogger.info("👋 Received Hello n°\(packetContent.helloId) from radio: \(packetContent.meshtasticRadioName)")
        
        // We can then update from the data we unserialized
        updateFromHelloPacket(packetContent: packetContent, directLink: peripheral.identifier.uuidString)
        
        // Wait a few seconds before sending HelloBack to avoid network congestion
        self.messageQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.sendHelloBack(peripheral: peripheral, characteristic: toRadio, helloId: packetContent.helloId)
        }
        
        // SendOnAllLinks ignores Hello and HelloBack packets, send without fearing redundance
        sendOnAllLinks(packet: packet, data: packet.toBinaryData() ?? Data(), pad: false, directedOnlyPeer: nil as PeerID?)
    }
    
    public func handleReceiveHelloBack(packet: BitchatPacket, peripheral: CBPeripheral) {
        // Deserialize the packet from the HelloBack protocole (almost the same as hello)
        guard let packetContent = try? deserializePeers(from: packet.payload) else {
            SecureLogger.error("❌ Unable to deserialize HelloBack packet from \(peripheral.name ?? "Unknown")")
            return
        }
        
        SecureLogger.info("👋 Received HelloBack n°\(packetContent.helloId) from radio: \(packetContent.meshtasticRadioName)")
        
        // We can then update from the data we unserialized
        updateFromHelloPacket(packetContent: packetContent, directLink: peripheral.identifier.uuidString)
        
        // SendOnAllLinks ignores Hello and HelloBack packets, send without fearing redundance
        sendOnAllLinks(packet: packet, data: packet.toBinaryData() ?? Data(), pad: false, directedOnlyPeer: nil as PeerID?)
    }
    
    // MARK: -- Bitchat-side meshtastic packets
    
    public func handleHelloBitchat(_ packet: BitchatPacket, from: PeerID) {
        // Deserialize the packet from the Hello protocole
        guard let packetContent = try? deserializePeers(from: packet.payload) else {
            SecureLogger.error("❌ Unable to deserialize HelloBack packet from bitchat")
            return
        }
        
        SecureLogger.info("👋 Received Hello n°\(packetContent.helloId) from radio: \(packetContent.meshtasticRadioName)")
        
        // We can then update from the data we unserialized
        updateFromHelloPacket(packetContent: packetContent, directLink: nil)
    }
    
    public func handleHelloBackBitchat(_ packet: BitchatPacket, from: PeerID) {
        // Deserialize the packet from the Hello protocole
        guard let packetContent = try? deserializePeers(from: packet.payload) else {
            SecureLogger.error("❌ Unable to deserialize HelloBack packet from bitchat")
            return
        }
        
        SecureLogger.info("👋 Received Hello n°\(packetContent.helloId) from radio: \(packetContent.meshtasticRadioName)")
        
        // We can then update from the data we unserialized
        updateFromHelloPacket(packetContent: packetContent, directLink: nil)
    }
    
    private func updateFromHelloPacket(packetContent: (helloId: UInt16, meshtasticRadioName: String, peers: [PeerID: PeerInfo]), directLink: String?) {
        notifyUI {
            var updatedPeers = self.peers
            
            var updatedMapping = self.peerToPeripheralUUID
        
            
            for (peerID, var peerInfo) in packetContent.peers {
                peerInfo.meshtastic = packetContent.meshtasticRadioName
                updatedPeers[peerID] = peerInfo
                if let stringUUID = directLink {
                    updatedMapping[peerID] = stringUUID
                }
            }
            
            // Reassign the entire dictionaries to trigger @Published
            self.peers = updatedPeers
            self.peerToPeripheralUUID = updatedMapping
        
            // Now we can publish the peers and update the UI
            self.publishFullPeerData()
        }
    }
    
    public func requestHelloBroadcast() {
        for radio in meshtasticServices {
            sendHello(peripheral: radio.peripheral, service: radio.service)
        }
    }
}


// MARK: -- Peer serialization --
/// In order to send the Hello and HelloBack messages for meshtastic,
/// Peers needs to be serialized in a list to be sent
///
/// Format:
///  ------------------------------------------------------------------------------------
/// | Hello ID | Radio Name   | Peer Count | Peer ID      | Nickname     | Flags  |  noiseKey         | singningKey         | LastSeen  |   x N peers
/// | 2B       | 2B len + N   | 2B         | 2B len + N   | 2B len + N   | 1 byte | 1B pres + 32B     | 1B pres + 32B       | 8B Uint64 |
///  ------------------------------------------------------------------------------------
///
///  Flags byte :
///     0 : is connected
///     1 : is verified nickname
///     2-7 : reserved
///

extension BLEService {
    private func serializePeer(_ peer: PeerInfo) -> Data {
        var data = Data()

        // peerID (String → UTF-8, préfixé par 2 bytes de longueur)
        appendLengthPrefixed(string: peer.peerID.id, to: &data)

        // nickname
        appendLengthPrefixed(string: peer.nickname, to: &data)

        // flags byte : bit0 = isConnected, bit1 = isVerifiedNickname
        var flags: UInt8 = 0
        if peer.isConnected        { flags |= 0x01 }
        if peer.isVerifiedNickname { flags |= 0x02 }
        data.append(flags)

        // noisePublicKey (presence byte + 32 bytes si présente)
        appendOptionalKey(peer.noisePublicKey, to: &data)

        // signingPublicKey
        appendOptionalKey(peer.signingPublicKey, to: &data)

        // lastSeen — UInt64 Unix timestamp (milliseconds), big-endian
        let ts = UInt64(peer.lastSeen.timeIntervalSince1970 * 1000).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: ts) { Array($0) })

        return data
    }
    
    func deserializePeers(from data: Data) throws -> (helloId: UInt16, meshtasticRadioName: String, peers: [PeerID: PeerInfo]) {
            var offset = 0
            var result: [PeerID: PeerInfo] = [:]

            let helloId = try readUInt16(from: data, offset: &offset)
            let meshtasticRadioName = try readLengthPrefixedString(from: data, offset: &offset)
        
            let count = try readUInt16(from: data, offset: &offset)

            for _ in 0..<count {
                let peer = try readPeer(from: data, offset: &offset)
                result[peer.peerID] = peer
            }
            return (helloId: helloId, meshtasticRadioName: meshtasticRadioName, peers: result)
        }

        private func readPeer(from data: Data, offset: inout Int) throws -> PeerInfo {
            let peerID   = try readLengthPrefixedString(from: data, offset: &offset)
            let nickname = try readLengthPrefixedString(from: data, offset: &offset)

            let flags             = try readByte(from: data, offset: &offset)
            let isConnected       = (flags & 0x01) != 0
            let isVerifiedNick    = (flags & 0x02) != 0

            let noiseKey   = try readOptionalKey(from: data, offset: &offset)
            let signingKey = try readOptionalKey(from: data, offset: &offset)

            let tsMillis   = try readUInt64(from: data, offset: &offset)
            let lastSeen   = Date(timeIntervalSince1970: Double(tsMillis) / 1000.0)

            return PeerInfo(
                peerID: PeerID(str: peerID),
                nickname: nickname,
                isConnected: isConnected,
                noisePublicKey: noiseKey,
                signingPublicKey: signingKey,
                isVerifiedNickname: isVerifiedNick,
                lastSeen: lastSeen
            )
        }
    
    // MARK: - Helpers write

        private func appendLengthPrefixed(string: String, to data: inout Data) {
            let bytes = Array(string.utf8)
            let len = UInt16(bytes.count).bigEndian
            data.append(contentsOf: withUnsafeBytes(of: len) { Array($0) })
            data.append(contentsOf: bytes)
        }

        private func appendOptionalKey(_ key: Data?, to data: inout Data) {
            if let key {
                data.append(0x01)
                data.append(key)
            } else {
                data.append(0x00)
            }
        }

        // MARK: - Helpers read

        enum SerializationError: Error {
            case unexpectedEndOfData
            case invalidStringEncoding
        }

        private func readByte(from data: Data, offset: inout Int) throws -> UInt8 {
            guard offset < data.count else { throw SerializationError.unexpectedEndOfData }
            defer { offset += 1 }
            return data[offset]
        }

        private func readUInt16(from data: Data, offset: inout Int) throws -> UInt16 {
            guard offset + 2 <= data.count else { throw SerializationError.unexpectedEndOfData }
            // Safe byte-by-byte construction to avoid alignment issues
            let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += 2
            return value
        }

        private func readUInt64(from data: Data, offset: inout Int) throws -> UInt64 {
            guard offset + 8 <= data.count else { throw SerializationError.unexpectedEndOfData }
            // Safe byte-by-byte construction to avoid alignment issues
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(data[offset + i])
            }
            offset += 8
            return value
        }

        private func readLengthPrefixedString(from data: Data, offset: inout Int) throws -> String {
            let len = Int(try readUInt16(from: data, offset: &offset))
            guard offset + len <= data.count else { throw SerializationError.unexpectedEndOfData }
            guard let str = String(bytes: data[offset..<offset+len], encoding: .utf8) else {
                throw SerializationError.invalidStringEncoding
            }
            offset += len
            return str
        }

        private func readOptionalKey(from data: Data, offset: inout Int) throws -> Data? {
            let presence = try readByte(from: data, offset: &offset)
            guard presence == 0x01 else { return nil }
            guard offset + 32 <= data.count else { throw SerializationError.unexpectedEndOfData }
            defer { offset += 32 }
            return data[offset..<offset+32]
        }
}
