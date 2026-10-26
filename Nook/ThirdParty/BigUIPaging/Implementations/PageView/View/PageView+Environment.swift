import SwiftUI

extension View {
    
    /// Sets the style of the page view within the current environment.
    public func pageViewStyle<S>(_ style: S) -> some View where S: PageViewStyle {
        self.environment(\.pageViewStyle, style)
    }
    
    /// Sets the orientation of the page view within the current environment.
    public func pageViewOrientation(_ axis: Axis) -> some View {
        self.environment(\.pageViewOrientation, axis)
    }
    
    /// Sets the spaces between pages, in points.
    ///
    /// This will only have effect on styles that support spacing, such as ``ScrollPageViewStyle``.
    public func pageViewSpacing(_ spacing: Double?) -> some View {
        self.environment(\.pageViewSpacing, spacing)
    }
    
    /// Nook: reports how far a swipe has carried the page view toward a neighbouring page, so
    /// anything that should move with the swipe can follow the finger (macOS pager only).
    public func onPageTransition(_ action: @escaping (PageTransition) -> Void) -> some View {
        self.environment(\.pageTransitionHandler, action)
    }

    /// Specifies the visibility of the background of pages within this view.
    public func pageContentBackground(_ visibility: Visibility) -> some View {
        self.environment(\.contentBackground, visibility)
    }
}

/// Nook: one step of a swipe between pages.
public struct PageTransition {
    /// The page the swipe is heading to; nil once the swipe is over.
    public let target: AnyHashable?
    /// 0 at the current page, 1 at `target`.
    public let fraction: CGFloat
    /// Set when the pager animates to `fraction` on its own (the settle after the fingers lift),
    /// so a follower can animate along with it.
    public let animation: Animation?
}

extension EnvironmentValues {

    struct PageTransitionKey: EnvironmentKey {
        static var defaultValue: ((PageTransition) -> Void)? = nil
    }

    var pageTransitionHandler: ((PageTransition) -> Void)? {
        get { self[PageTransitionKey.self] }
        set { self[PageTransitionKey.self] = newValue }
    }
    
    struct StyleKey: EnvironmentKey {
        static var defaultValue: any PageViewStyle = PlainPageViewStyle()
    }
    
    var pageViewStyle: any PageViewStyle {
        get { self[StyleKey.self] }
        set { self[StyleKey.self] = newValue }
    }
    
    struct OrientationKey: EnvironmentKey {
        static var defaultValue: Axis = .horizontal
    }
    
    var pageViewOrientation: Axis {
        get { self[OrientationKey.self] }
        set { self[OrientationKey.self] = newValue }
    }
    
    struct SpacingKey: EnvironmentKey {
        static var defaultValue: Double? = nil
    }
    
    var pageViewSpacing: Double? {
        get { self[SpacingKey.self] }
        set { self[SpacingKey.self] = newValue }
    }
    
    struct ContentBackgroundVisibilityKey: EnvironmentKey {
        static var defaultValue: Visibility = .automatic
    }
    
    var contentBackground: Visibility {
        get { self[ContentBackgroundVisibilityKey.self] }
        set { self[ContentBackgroundVisibilityKey.self] = newValue }
    }
    
    struct NavigateActionKey: EnvironmentKey {
        static var defaultValue: PageViewNavigateAction = .default
    }
        
    /// Navigates the page view in the environment.
    public var navigatePageView: PageViewNavigateAction {
        get { self[NavigateActionKey.self] }
        set { self[NavigateActionKey.self] = newValue }
    }
    
    struct CanNavigateKey: EnvironmentKey {
        static var defaultValue = PageViewDirection()
    }
    
    /// A set of the currently allowed directions of travel.
    ///
    /// Check the set for a specific direction to to disable navigation UI elements.
    ///
    /// ```swift
    /// @Environment(\.canNavigatePageView) private var canNavigate
    ///
    /// var body: some View {
    ///     Button {
    ///         ...
    ///     } label: {
    ///         ...
    ///     }
    ///     .disabled(canNavigate.contains(direction) == false)
    /// }
    /// ```
    public var canNavigatePageView: PageViewDirection {
        get { self[CanNavigateKey.self] }
        set { self[CanNavigateKey.self] = newValue }
    }
}

