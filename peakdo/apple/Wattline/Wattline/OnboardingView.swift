import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                    Text("Your power, at a glance")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("See what your power station is doing and keep the controls you use close at hand.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    FeaturePane(icon: "gauge.with.dots.needle.67percent", title: "Glanceable", detail: "Live battery and port status without digging through menus.")
                    FeaturePane(icon: "hand.raised.fill", title: "Private", detail: "Device data stays between this app and your power station.")
                    FeaturePane(icon: "gearshape.2.fill", title: "Automatable", detail: "A foundation for dependable routines and controls.")
                }

                VStack(spacing: 12) {
                    Button("Connect a device") {
                        model.requestBluetoothAfterPriming()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)

                    Button("Try Demo Mode") {
                        model.enterDemo()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(28)
        }
    }
}

private struct FeaturePane: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}
