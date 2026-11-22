import CoreGraphics

/// The sizes of the in-call card for the height the window gives it.
///
/// Until the call connects the card is small: who is being called and the
/// button to hang up. Once connected it opens to its full size and keeps one
/// height whether the keypad is open or closed, and the control row keeps
/// one size, so opening the keypad never moves the buttons under the
/// pointer. A tall window gets the full-size card; a short one shrinks the
/// pieces instead of scrolling, and only the smallest windows give up the
/// waveform while the keypad is open.
struct InCallLayout: Equatable {
    static let connectedCardWidth: CGFloat = 560
    /// The card while the call is being set up.
    static let compactCardWidth: CGFloat = 430
    static let maximumCardHeight: CGFloat = 680
    /// Distance between the centres of two control buttons.
    static let controlPitch: CGFloat = 84
    /// Distance between the centres of two keypad columns. The outer columns
    /// sit exactly above the first and the last control button.
    static let keypadPitch: CGFloat = controlPitch * 1.5
    static let topRowHeight: CGFloat = 22
    /// Room kept above the card for the window's title bar.
    static let topMargin: CGFloat = 30
    static let bottomMargin: CGFloat = 18

    let keypadOpen: Bool
    /// False while the call is being set up: the small card.
    let isConnected: Bool
    let cardWidth: CGFloat
    /// The card's height. It is larger than the available height only when
    /// the window is too short even for the smallest sizes; the page scrolls
    /// then.
    let cardHeight: CGFloat
    let showsWaveform: Bool
    /// Avatar, name and timer on one line instead of stacked.
    let usesMiniHero: Bool

    let paddingTop: CGFloat
    let paddingBottom: CGFloat
    let controlDiameter: CGFloat
    let keySize: CGFloat
    let keyRowGap: CGFloat
    let digitsHeight: CGFloat
    let keypadTopGap: CGFloat
    let keysTopGap: CGFloat
    let avatar: CGFloat
    let heroTopGap: CGFloat
    /// Between the avatar and the name.
    let heroNameGap: CGFloat
    /// Between the number and the timer.
    let heroTimerGap: CGFloat
    let miniAvatar: CGFloat
    let miniHeroTopGap: CGFloat
    let laneHeight: CGFloat
    let panelPaddingTop: CGFloat
    let panelPaddingBottom: CGFloat
    let minimumGapAboveWaveform: CGFloat
    let minimumGapAboveControls: CGFloat

    /// Width from the outer edge of the first control to the outer edge of
    /// the last one. The sent-digits field is exactly this wide.
    var controlRowExtent: CGFloat {
        Self.controlPitch * 3 + controlDiameter
    }

    /// Space between two keys in a row, so their centres are one keypad
    /// pitch apart.
    var keyColumnGap: CGFloat {
        Self.keypadPitch - keySize
    }

    /// - Parameters:
    ///   - keypadOpen: ignored until the call is connected.
    ///   - isConnected: the call has been answered, so there are voices to
    ///     show and controls to offer.
    init(availableHeight: CGFloat, keypadOpen requestedKeypad: Bool, isConnected: Bool) {
        let keypadOpen = requestedKeypad && isConnected
        let hasWaveform = isConnected
        let height = min(Self.maximumCardHeight, max(0, availableHeight))
        // The control row and the keypad take their size from what the open
        // keypad needs, in both states, so they never resize on a toggle.
        let openSmallest = Self.openHeight(scale: 0, showsWaveform: true)
        let openLargest = Self.openHeight(scale: 1, showsWaveform: true)
        let scale = Self.fraction(height, from: openSmallest, to: openLargest)

        self.keypadOpen = keypadOpen
        self.isConnected = isConnected
        cardWidth = isConnected ? Self.connectedCardWidth : Self.compactCardWidth
        paddingTop = Self.paddingTop(scale)
        paddingBottom = Self.paddingBottom(scale)
        controlDiameter = Self.controlDiameter(scale)
        keySize = Self.keySize(scale)
        keyRowGap = Self.keyRowGap(scale)
        digitsHeight = Self.digitsHeight(scale)
        keypadTopGap = Self.keypadTopGap(scale)
        keysTopGap = Self.keysTopGap(scale)
        miniAvatar = Self.miniAvatar(scale)
        miniHeroTopGap = Self.miniHeroTopGap(scale)

        guard isConnected else {
            // Setting up: the card hugs the hero and the buttons, with one
            // comfortable gap between them.
            let gap = Self.compactGap(scale)
            let fixed = Self.paddingTop(scale) + Self.paddingBottom(scale) + Self.topRowHeight +
                gap + Self.controlsHeight(scale)
            let heroScale = Self.fraction(
                height - fixed,
                from: Self.heroHeight(0),
                to: Self.heroHeight(1)
            )
            minimumGapAboveWaveform = (gap / 2).rounded(.down)
            minimumGapAboveControls = gap - (gap / 2).rounded(.down)
            usesMiniHero = false
            showsWaveform = false
            avatar = Self.avatar(heroScale)
            heroTopGap = Self.heroTopGap(heroScale)
            heroNameGap = Self.heroNameGap(heroScale)
            heroTimerGap = Self.heroTimerGap(heroScale)
            laneHeight = Self.closedLaneHeight(heroScale)
            panelPaddingTop = Self.panelPaddingTop(heroScale)
            panelPaddingBottom = Self.panelPaddingBottom(heroScale)
            cardHeight = fixed + Self.heroHeight(heroScale)
            return
        }

        minimumGapAboveWaveform = Self.gapAboveWaveform(scale)
        minimumGapAboveControls = Self.gapAboveControls(scale)

        if keypadOpen {
            let fitsWaveform = height >= openSmallest
            let waveform = hasWaveform && fitsWaveform
            usesMiniHero = true
            showsWaveform = waveform
            avatar = Self.avatar(1)
            heroTopGap = Self.heroTopGap(1)
            heroNameGap = Self.heroNameGap(1)
            heroTimerGap = Self.heroTimerGap(1)
            laneHeight = Self.openLaneHeight(scale)
            panelPaddingTop = Self.panelPaddingTop(scale)
            panelPaddingBottom = Self.panelPaddingBottom(scale)
            cardHeight = max(height, Self.openHeight(scale: scale, showsWaveform: waveform))
            return
        }

        // Closed: whatever the fixed pieces leave goes to the big avatar and
        // the tall waveform lanes.
        let fixed = Self.paddingTop(scale) + Self.paddingBottom(scale) + Self.topRowHeight +
            Self.gapAboveWaveform(scale) + Self.gapAboveControls(scale) +
            Self.controlsHeight(scale)
        let flexible = height - fixed
        let smallest = Self.heroHeight(0) + (hasWaveform ? Self.closedPanelHeight(0) : 0)
        let largest = Self.heroHeight(1) + (hasWaveform ? Self.closedPanelHeight(1) : 0)
        let closedScale = Self.fraction(flexible, from: smallest, to: largest)
        let mini = flexible < smallest

        usesMiniHero = mini
        showsWaveform = hasWaveform
        avatar = Self.avatar(closedScale)
        heroTopGap = Self.heroTopGap(closedScale)
        heroNameGap = Self.heroNameGap(closedScale)
        heroTimerGap = Self.heroTimerGap(closedScale)
        laneHeight = Self.closedLaneHeight(closedScale)
        panelPaddingTop = Self.panelPaddingTop(closedScale)
        panelPaddingBottom = Self.panelPaddingBottom(closedScale)
        let hero = mini ? Self.miniHeroHeight(scale) : Self.heroHeight(closedScale)
        let panel = hasWaveform ? Self.closedPanelHeight(closedScale) : 0
        cardHeight = max(height, fixed + hero + panel)
    }

    // MARK: - Pieces

    /// Text heights the budget assumes: name, number and timer lines, the
    /// label under a control, and the "who is speaking" line.
    private static let nameLine: CGFloat = 32
    private static let numberLine: CGFloat = 20
    private static let timerLine: CGFloat = 26
    private static let controlLabel: CGFloat = 22
    private static let hintLine: CGFloat = 20
    private static let laneDivider: CGFloat = 7

    private static func mix(_ small: CGFloat, _ large: CGFloat, _ scale: CGFloat) -> CGFloat {
        (small + (large - small) * scale).rounded(.down)
    }

    private static func fraction(_ value: CGFloat, from small: CGFloat, to large: CGFloat) -> CGFloat {
        guard large > small else { return 1 }
        return max(0, min(1, (value - small) / (large - small)))
    }

    private static func paddingTop(_ s: CGFloat) -> CGFloat { mix(14, 22, s) }
    private static func paddingBottom(_ s: CGFloat) -> CGFloat { mix(14, 24, s) }
    private static func controlDiameter(_ s: CGFloat) -> CGFloat { mix(50, 58, s) }
    private static func keySize(_ s: CGFloat) -> CGFloat { mix(44, 58, s) }
    private static func keyRowGap(_ s: CGFloat) -> CGFloat { mix(7, 16, s) }
    private static func digitsHeight(_ s: CGFloat) -> CGFloat { mix(32, 40, s) }
    private static func keypadTopGap(_ s: CGFloat) -> CGFloat { mix(10, 14, s) }
    private static func keysTopGap(_ s: CGFloat) -> CGFloat { mix(10, 16, s) }
    private static func miniAvatar(_ s: CGFloat) -> CGFloat { mix(36, 44, s) }
    private static func miniHeroTopGap(_ s: CGFloat) -> CGFloat { mix(10, 14, s) }
    private static func gapAboveWaveform(_ s: CGFloat) -> CGFloat { mix(6, 16, s) }
    private static func gapAboveControls(_ s: CGFloat) -> CGFloat { mix(6, 10, s) }
    private static func compactGap(_ s: CGFloat) -> CGFloat { mix(20, 36, s) }
    private static func openLaneHeight(_ s: CGFloat) -> CGFloat { mix(16, 24, s) }
    private static func panelPaddingTop(_ s: CGFloat) -> CGFloat { mix(8, 12, s) }
    private static func panelPaddingBottom(_ s: CGFloat) -> CGFloat { mix(8, 10, s) }
    private static func avatar(_ s: CGFloat) -> CGFloat { mix(64, 100, s) }
    private static func heroTopGap(_ s: CGFloat) -> CGFloat { mix(10, 20, s) }
    private static func heroNameGap(_ s: CGFloat) -> CGFloat { mix(8, 10, s) }
    private static func heroTimerGap(_ s: CGFloat) -> CGFloat { mix(4, 6, s) }
    private static func closedLaneHeight(_ s: CGFloat) -> CGFloat { mix(34, 62, s) }

    private static func controlsHeight(_ s: CGFloat) -> CGFloat {
        controlDiameter(s) + controlLabel
    }

    private static func miniHeroHeight(_ s: CGFloat) -> CGFloat {
        miniHeroTopGap(s) + miniAvatar(s)
    }

    private static func heroHeight(_ s: CGFloat) -> CGFloat {
        heroTopGap(s) + avatar(s) + heroNameGap(s) + nameLine + numberLine +
            heroTimerGap(s) + timerLine
    }

    private static func keypadHeight(_ s: CGFloat) -> CGFloat {
        keypadTopGap(s) + digitsHeight(s) + keysTopGap(s) + keySize(s) * 4 + keyRowGap(s) * 3
    }

    private static func openPanelHeight(_ s: CGFloat) -> CGFloat {
        panelPaddingTop(s) + openLaneHeight(s) * 2 + laneDivider + panelPaddingBottom(s)
    }

    private static func closedPanelHeight(_ s: CGFloat) -> CGFloat {
        panelPaddingTop(s) + closedLaneHeight(s) * 2 + laneDivider + hintLine +
            panelPaddingBottom(s)
    }

    private static func openHeight(scale s: CGFloat, showsWaveform: Bool) -> CGFloat {
        paddingTop(s) + paddingBottom(s) + topRowHeight + miniHeroHeight(s) +
            gapAboveWaveform(s) + (showsWaveform ? openPanelHeight(s) : 0) +
            keypadHeight(s) + gapAboveControls(s) + controlsHeight(s)
    }
}
