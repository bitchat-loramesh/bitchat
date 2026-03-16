//
// MeshtasticManagementView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import CoreBluetooth

/// A view for discovering and managing Meshtastic radio connections via Bluetooth
struct MeshtasticManagementView: View {
    // MARK: - Properties
    
    /// Binding to control whether this sheet is presented
    @Binding var isPresented: Bool
    
    /// Access to the main chat view model
    @EnvironmentObject var viewModel: ChatViewModel
    
    /// Current color scheme (light or dark mode)
    @Environment(\.colorScheme) var colorScheme
    
    // MARK: - Computed Properties
    
    /// Background color based on current theme
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    /// Primary text color based on current theme
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    /// Secondary text color (slightly transparent)
    private var secondaryTextColor: Color {
        textColor.opacity(0.7)
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Bluetooth status section
                    bluetoothStatusSection
                    
                    Divider()
                        .padding(.vertical, 8)
                    
                    // Discovered devices section
                    discoveredDevicesSection
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        #if os(macOS)
        .frame(minWidth: 450, minHeight: 500)
        #endif
    }
    
    // MARK: - View Components
    
    /// Header with title and close button
    private var headerView: some View {
        HStack(spacing: 12) {
            Text("Meshtastic Radios")
                .font(.bitchatSystem(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
            
            Spacer()
            
            // Close button
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(backgroundColor)
    }
    
    /// Bluetooth status information
    private var bluetoothStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bluetooth Status")
                .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(textColor)
            
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.bluetoothState == .poweredOn ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                Text(viewModel.bluetoothState == .poweredOn ? "Enabled" : "Disabled")
                    .font(.bitchatSystem(size: 13, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            
            if viewModel.bluetoothState != .poweredOn {
                Text("Please enable Bluetooth to discover Meshtastic devices")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(Color.orange)
                    .padding(.top, 4)
            }
        }
    }
    
    /// List of discovered Meshtastic devices
    private var discoveredDevicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discovered Devices")
                .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(textColor)
            
            if viewModel.meshService is BLEService {
                let bleService = viewModel.meshService as! BLEService
                if bleService.getMeshtasticDevice().isEmpty {
                    Text("No Meshtastic devices found")
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                        .padding(.top, 8)
                } else {
                    List(bleService.getMeshtasticDevice(), id: \.1.identifier) { device in
                        Button(action: {
                            if !device.connected {
                                bleService.connectToMeshtastic(peripheral: device.1, service: device.0)
                            } else {
                                bleService.disconnectFromMeshtastic(peripheral: device.1)
                            }
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Circle()
                                        .fill(device.2 ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    Text(device.1.name ?? "Unknown Device")
                                        .font(.bitchatSystem(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundColor(textColor)
                                    
                                    Text(device.1.identifier.uuidString)
                                        .font(.bitchatSystem(size: 11, design: .monospaced))
                                        .foregroundColor(secondaryTextColor)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.bitchatSystem(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minHeight: 200)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Returns appropriate color for signal strength
    private func signalColor(for rssi: Int) -> Color {
        if rssi > -60 {
            return Color.green
        } else if rssi > -80 {
            return Color.orange
        } else {
            return Color.red
        }
    }
}

