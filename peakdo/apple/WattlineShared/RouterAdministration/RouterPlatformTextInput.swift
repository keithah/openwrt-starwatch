import SwiftUI

extension View {
    @ViewBuilder
    func routerLiteralInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func routerNumberInput() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func routerDecimalInput() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func routerURLInput() -> some View {
        #if os(iOS)
        keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func routerPINInput() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
            .textContentType(.password)
        #else
        self
        #endif
    }

    @ViewBuilder
    func routerOneTimeCodeInput() -> some View {
        #if os(iOS)
        textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
