"""V2.22.0 compile compatibility for Pay Profile SwiftUI sections."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
p = ROOT / "RAIDORoster" / "EarningsView.swift"
s = p.read_text()

old = '''            Section("Pay Profile") {
                TextField("Profile name", text: $profile.name)
                Picker("Rank", selection: $profile.rank) {
                    ForEach(EarningsRankPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Default BLH role", selection: $profile.defaultRole) {
                    ForEach(EarningsRole.allCases) { Text($0.label).tag($0) }
                }
                TextField("Home base · IATA", text: $profile.homeAirport)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Currency · ISO", text: $profile.currency)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Effective month · YYYY-MM", text: $effectiveMonth)
                    .keyboardType(.numbersAndPunctuation)
            } footer: {
                Text("Saving a new effective month creates a new contract revision. Older months keep the rules that were effective then.")
            }'''
new = '''            Section {
                TextField("Profile name", text: $profile.name)
                Picker("Rank", selection: $profile.rank) {
                    ForEach(EarningsRankPreset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Default BLH role", selection: $profile.defaultRole) {
                    ForEach(EarningsRole.allCases) { Text($0.label).tag($0) }
                }
                TextField("Home base · IATA", text: $profile.homeAirport)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Currency · ISO", text: $profile.currency)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Effective month · YYYY-MM", text: $effectiveMonth)
                    .keyboardType(.numbersAndPunctuation)
            } header: {
                Text("Pay Profile")
            } footer: {
                Text("Saving a new effective month creates a new contract revision. Older months keep the rules that were effective then.")
            }'''
if s.count(old) != 1:
    raise RuntimeError(f"Pay Profile section anchor changed; found {s.count(old)}")
s = s.replace(old, new, 1)

old = '''            Section("Daily allowance") {
                profileMoneyField("Amount per eligible day", cents: $profile.dailyAllowanceCents)
                Toggle("Flight · home base", isOn: $profile.flightHomeDaily)
                Toggle("Flight · away", isOn: $profile.flightAwayDaily)
                Toggle("Standby", isOn: $profile.standbyDaily)
                Toggle("Positioning", isOn: $profile.positioningDaily)
                Toggle("OFF / other day away", isOn: $profile.offAwayDaily)
                Toggle("Reserve", isOn: $profile.reserveDaily)
                Toggle("DND / leave / sickness", isOn: $profile.absenceDaily)
            } footer: {
                Text("These switches control the daily allowance only. Block-hour pay and duty-day supplements are calculated separately, so components can stack.")
            }'''
new = '''            Section {
                profileMoneyField("Amount per eligible day", cents: $profile.dailyAllowanceCents)
                Toggle("Flight · home base", isOn: $profile.flightHomeDaily)
                Toggle("Flight · away", isOn: $profile.flightAwayDaily)
                Toggle("Standby", isOn: $profile.standbyDaily)
                Toggle("Positioning", isOn: $profile.positioningDaily)
                Toggle("OFF / other day away", isOn: $profile.offAwayDaily)
                Toggle("Reserve", isOn: $profile.reserveDaily)
                Toggle("DND / leave / sickness", isOn: $profile.absenceDaily)
            } header: {
                Text("Daily allowance")
            } footer: {
                Text("These switches control the daily allowance only. Block-hour pay and duty-day supplements are calculated separately, so components can stack.")
            }'''
if s.count(old) != 1:
    raise RuntimeError(f"Daily allowance section anchor changed; found {s.count(old)}")
s = s.replace(old, new, 1)

p.write_text(s)
print("V2.22.0 Pay Profile section compile compatibility applied")
