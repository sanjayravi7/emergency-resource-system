# AUTH KEYBOARD STABILITY — ROOT-CAUSE FIX REPORT

Scope: the ERAS Flutter auth experience (`frontend/emergency_app`).
Objective: opening the Android soft keyboard must not change the auth
composition — only the scroll/padding needed to keep the focused field
reachable.

---

## 1. ROOT CAUSE

The previous change (`PageStorageKey`, `resizeToAvoidBottomInset: false`) did
not remove the coupling between the keyboard and the composition. Three
independent causes remained in `lib/widgets/auth_shell.dart`:

### 1.1 The keyboard inset was applied to the whole composition

`AuthShell` wrapped the **entire** `Stack` (backdrop + composition) in
`_AuthKeyboardInsetRegion` → `AnimatedPadding(bottom: viewInsets.bottom)`.

```
Scaffold(resizeToAvoidBottomInset: false)
  └ AnimatedContainer (gradient)
      └ SafeArea
          └ AnimatedPadding(bottom: viewInsets.bottom)   <-- squeezed EVERYTHING
              └ Stack
                  ├ backdrop (gradient drift / grid painter)
                  └ _DesktopComposition | _NarrowComposition
```

Consequences when the keyboard arrives:

* the backdrop (`_AmbientBackdrop`, `_GridPainter`) was compressed into the
  reduced box — a visible full-page re-paint that reads as a "refresh";
* every constraint-dependent widget below was re-laid-out into a shorter box.

### 1.2 Constraint-derived breakpoints below that squeeze

* `_AuthCardColumn` (desktop card column) used
  `ConstrainedBox(minHeight: constraints.maxHeight)` + `Column(center)`.
  When `constraints.maxHeight` dropped below the card height, the column
  stopped centring and snapped the card to the top of its column — the
  "card jumps / recenters" symptom in requirement §6.
* `_StoryColumn` used `constraints.maxHeight < _fixedHeight(s) + 130 * s` to
  choose between the flex branch and a **scroll fallback branch**. On a
  desktop-width viewport with a soft keyboard (tablet / foldable) that
  threshold flips, i.e. a *structural* change of the widget tree caused purely
  by `viewInsets.bottom`.
* `_NarrowComposition`'s `showHero` / `showHeroVisuals` thresholds were read
  from a `Size` computed in `AuthShell.build`. That value happened to come from
  `MediaQuery.sizeOf` − `viewPadding`, but nothing enforced or documented it,
  and on platforms that shrink the reported window for the IME (Android
  `adjustResize`) that height **is** keyboard dependent, so the hero/visual
  breakpoint could still flip on focus.

### 1.3 Two competing keyboard animations

`_AuthScrollRegion` restored the pre-keyboard scroll offset while the root
`AnimatedPadding` simultaneously animated the viewport height. The two ran
against each other across the whole page instead of only inside the scroll
viewport.

---

## 2. FIX

The shell now has two strictly separated channels.

### A. Stable viewport → composition (never sees the keyboard)

New public value type `AuthLayoutMetrics` in `lib/widgets/auth_shell.dart`:

* `viewport` — `MediaQuery.sizeOf` minus `MediaQuery.viewPaddingOf`
  (the **physical** safe area: status bar, notch, gesture/navigation bar),
* `desktop`, `scale`, `compactPhone`, `showHero`, `showHeroVisuals`.

All breakpoint constants moved onto `AuthShell` and are resolved in one place
(`AuthLayoutMetrics.forViewport`):

| decision | source |
| --- | --- |
| desktop vs narrow | `viewport.width >= 1150` |
| responsive scale | `viewport.width` |
| compact phone | `viewport.width < 600` |
| hero heading | `!compactPhone && viewport.height >= 700` |
| hero illustration + flow strip | `viewport.width >= 760 && viewport.height >= 720` |

`_AuthLayoutScope` (a `StatefulWidget` + `_AuthMetrics` `InheritedWidget`)
resolves the metrics and **freezes the height while the keyboard is up**. This
makes the metrics keyboard-independent under *both* platform behaviours:

* platform reports the keyboard only as `viewInsets.bottom` (window height
  constant) → the computed height never changes, nothing to freeze;
* platform also shrinks the reported window (Android `adjustResize`) → the
  height measured with the keyboard closed is kept.

The width is never frozen, so a real rotation / split-screen change still
updates the composition immediately. Because the composition subtree is passed
in as an already built `child`, a keyboard frame rebuilds `_AuthLayoutScope`
only — the subtree below keeps element identity, state and animations.

`_AuthComposition` reads the metrics *below* the scope and picks
`_DesktopComposition` or `_NarrowComposition`. `_NarrowComposition` no longer
takes a raw `Size` and no longer reads any constraint.

### B. Keyboard inset → scroll viewport only

`_AuthKeyboardInsetRegion` was moved **out of the root** and now wraps exactly
one scrollable region:

* `_AuthScrollRegion` (narrow composition) — wraps its `SingleChildScrollView`;
* `_AuthCardColumn` (desktop composition) — wraps its `SingleChildScrollView`,
  and critically the `LayoutBuilder` that measures the centring anchor now runs
  **above** the inset region, so `minHeight` is the keyboard-free height and the
  card can no longer re-centre or snap to the top.

The rest of the desktop composition (`_StoryColumn`, `_SideColumn`) is never
inset, so the illustration, flow strip, status cards and trust card keep their
exact geometry and `_StoryColumn`'s scroll fallback cannot flip.

The narrow-composition scroll viewport ends up exactly the same height as
before (`safe height − viewInsets.bottom`), so Flutter's own show-on-screen
pass still scrolls a focused field clear of the keyboard, and the existing
offset save/restore logic in `_AuthScrollRegionState` is unchanged.

### Resulting tree

```
AuthShell (reads Theme only — no MediaQuery dependency at all)
  └ Scaffold(resizeToAvoidBottomInset: false)
      └ AnimatedContainer (gradient, full screen, never compressed)
          └ _AuthLayoutScope            <-- A: stable viewport, keyboard frozen
              └ _AuthMetrics (InheritedWidget)
                  └ SafeArea(maintainBottomViewPadding: true)
                      └ Stack
                          ├ backdrop (full screen, never compressed)
                          └ _AuthComposition
                              ├ _DesktopComposition
                              │   ├ _StoryColumn      (stable)
                              │   ├ _AuthCardColumn
                              │   │   └ LayoutBuilder (stable anchor)
                              │   │       └ _AuthKeyboardInsetRegion  <-- B
                              │   │           └ SingleChildScrollView
                              │   └ _SideColumn       (stable)
                              └ _NarrowComposition
                                  └ _AuthScrollRegion
                                      └ _AuthKeyboardInsetRegion      <-- B
                                          └ SingleChildScrollView
```

`MediaQuery.viewInsets` is now read in exactly three places, none of which can
reach a breakpoint:

1. `_AuthLayoutScopeState._resolve()` — reads it only to *ignore* it (freeze);
2. `_AuthKeyboardInsetRegion` — converts it into padding on one scroll viewport;
3. `_AuthScrollRegionState.didChangeDependencies()` — scroll offset save/restore.

### Other requirements

* **§7 animation identity** — every animated block in `_NarrowComposition`
  (hero lines, subtext, illustration, flow strip) now carries an explicit
  `ValueKey`, so animation identity is key-driven rather than index-driven even
  if a sibling block changes. `EntranceReveal` already guards with `_started`
  in `didChangeDependencies`, so it can never replay. `AnimatedSwap`,
  `FocusGlow`, `HoverLift`, `PressableScale`, `TogglePulse` were audited: none
  of them reads a viewport metric and each keeps its state in its own `State`.
* **§8 controllers** — audited `LoginScreen`, `RegisterScreen`,
  `ForgotPasswordScreen`, `EmailVerificationScreen`, `_AuthScrollRegionState`,
  `_EntranceRevealState`, `_AuthNetworkDiagramState`, `_AmbientBackdropState`,
  `_RoleSelectionCardState`, `_PointerParallaxState`, `_TogglePulseState`:
  every `TextEditingController`, `FocusNode`, `AnimationController` and
  `ScrollController` is owned by `State` and disposed. Nothing is created in
  `build()`.
* **§9 focus** — no focus-driven `setState` above the field. `FocusGlow` and
  `_RoleSelectionCard` each `setState` on themselves only; `AuthShell` does not
  observe focus at all.
* **§10 PageStorageKey** — kept: the narrow scroll region still keys itself with
  `PageStorageKey<Key>(child.key)`, so login / register / reset / verification
  keep distinct scroll storage. It is no longer load-bearing for the keyboard
  fix.
* **§12 messages** — `AuthInlineMessage` keeps its `AnimatedSize` expand/collapse
  and sits inside the card, so the Google error, validation errors, verification
  notices and reset notices grow the card smoothly without touching the shell.
* **§13 safe area** — `SafeArea(maintainBottomViewPadding: true)` keeps the
  navigation/gesture edge constant; `viewPadding` (physical) and `viewInsets`
  (keyboard) are now used for different purposes and are documented as such.
* **§14** — no colours, typography, card style, branding, motion language,
  Firebase architecture, JWT/Google authentication, verification or reset flow
  were changed. No public API was removed (`AuthShell.referenceWidth`,
  `referenceHeight`, `desktopBreakpoint` are all still present).

---

## 3. FILES CHANGED

| file | change |
| --- | --- |
| `frontend/emergency_app/lib/widgets/auth_shell.dart` | The keyboard fix. Added `AuthLayoutMetrics`, `_AuthMetrics`, `_AuthLayoutScope`, `_AuthComposition`; moved `_AuthKeyboardInsetRegion` from the root of the shell to the two scroll viewports; `_NarrowComposition` and `_DesktopComposition` now take `AuthLayoutMetrics` instead of a raw `Size`/`scale`; `_AuthCardColumn`'s centring anchor is measured above the keyboard inset; `_StoryColumn`'s scroll fallback documented and structurally isolated; explicit keys added to the hero entrance reveals. |
| `frontend/emergency_app/lib/widgets/auth_visuals.dart` | One-line overflow guard in `AuthPrimaryButton` (see §5.3). |
| `frontend/emergency_app/test/auth_keyboard_composition_test.dart` | New regression suite (§4). |
| `frontend/emergency_app/test/auth_mobile_stability_test.dart` | Compile fix + real safe area in the harness (§5.2). |
| `frontend/emergency_app/test/forgot_password_flow_test.dart` | Compile fix + real safe area in the harness (§5.2). |
| `frontend/emergency_app/test/google_signin_flow_test.dart` | `dart format` only. |
| `AUTH_KEYBOARD_STABILITY_REPORT.md` | This report. |

No design, colour, typography, branding, motion, backend, Firebase or auth-logic
change. `pubspec.lock` is untouched.

---

## 4. TESTS ADDED

`frontend/emergency_app/test/auth_keyboard_composition_test.dart` — 11 widget
tests that drive real `MediaQuery` keyboard changes through
`tester.view.viewInsets`:

| requirement | test |
| --- | --- |
| A / B / C | `A/B/C: keyboard insets never change the auth composition` — tablet viewport where the hero *is* shown; asserts identical `AuthLayoutMetrics` (viewport, scale, desktop, showHero, showHeroVisuals) at `viewInsets.bottom` 0 and 400, hero/illustration/flow strip/card all still present, same `ModalRoute`, same page `State`, same scroll-region `State`, same entrance `State`, and unchanged hero + card geometry. |
| C (second platform behaviour) | `C: a window resized for the IME cannot move a breakpoint` — shrinks `physicalSize` *and* reports the inset simultaneously (Android `adjustResize`), asserts the frozen metrics and that the hero survives. |
| D / E | `D/E: login keeps email and password through focus + keyboard` — focus email → inset 400 → text/focus/controller identity retained; then focus password → inset 420 → both fields retained. |
| F | `F: register keeps its form and role while the keyboard opens`. |
| G | `G: password reset keeps its step while the keyboard opens` — drives step 1 → step 2 against a mock backend and asserts the correct step (`reset-code`, not `reset-email`) survives the keyboard. |
| H | `H: verification keeps its code while the keyboard opens`. |
| I | `I: entrance animations do not restart when viewInsets change` — ten entrance keys; asserts identical `State` objects and opacity 1 one frame into the keyboard animation (a replay would drop to 0). |
| §6 | `desktop card and columns keep their geometry with the keyboard` — the card, the illustration, the trust card and the status cards all keep their exact rect while the keyboard is open. **This test fails on the pre-fix code** (the card re-centred / snapped to the top of its column). |
| §4 / §6 | `a phone page neither reflows nor resets its scroll offset` — brand and card rects and the scroll offset are unchanged, while `maxScrollExtent` grows (scrolling is preserved). |
| §12 | `the Google error expands without restarting the composition` — reproduces `Google sign-in is not configured on this server` and asserts no route/state/animation/metrics change, then repeats with the keyboard open. |
| §10 / J | `J: every auth screen keeps its own page storage key` — asserts the four distinct `PageStorageKey`s. |
| §13 | `13: the physical safe area and the keyboard inset stay apart` — asserts `viewport == Size(360, 752)` for a 360x800 window with a 24/24 safe area, unchanged at `viewInsets.bottom == 320`, and that the brand stays inside the safe area. |
| §17 | `17: repeated email/password focus never looks like a refresh` — three full open/close cycles alternating focus between email and password, asserting page state, route, scroll-region state, entrance state, entrance opacity, metrics and both field values on every step. |

---

## 5. VALIDATION RESULTS

The authoring sandbox had **no Flutter SDK, no Dart SDK, no Android SDK, no JDK
and no outbound network**, so nothing could be run locally. The toolchain was
therefore borrowed from GitHub Actions: a throwaway workflow ran the real
commands on the branch and pushed the results back (that workflow and its
`.probe/` output directory are removed again before merge).

Toolchain: **Flutter 3.47.6 • channel stable • Dart 3.13.5** (ubuntu-latest).

### 5.1 The three required commands

| step | result |
| --- | --- |
| `dart format --output=none --set-exit-if-changed .` | **PASS** — `Formatted 75 files (0 changed) in 0.41 seconds.`, exit 0 |
| `flutter analyze` | **PASS** — `No issues found! (ran in 8.9s)`, exit 0 |
| `flutter test` | **PASS** — `00:50 +323: All tests passed!`, exit 0 |

All 323 tests pass, including the previously pinned geometry suites
(`auth_visual_layout_test`: desktop 1648x926, phone 390x844, tablet 834x1112)
and the pre-existing keyboard suite (`auth_mobile_stability_test`).

### 5.2 Two pre-existing defects had to be fixed to get any test signal at all

`main` was already red: its Flutter workflow run for PR #71 failed at *Verify
formatting*, and because that step short-circuits the job, the following was
invisible until now.

1. **15 compile errors — `flutter analyze` and `flutter test` could not even
   build.** `TextFormField` stores its focus node in its *state*, not on the
   widget, so `tester.widget<TextFormField>(...).focusNode` does not exist.
   10 of the 15 were already on `main`
   (`auth_mobile_stability_test.dart`, `forgot_password_flow_test.dart`), 5 were
   in the new suite. Fixed with a `_fieldFocusNode(tester, finder)` helper in
   each file that reads the node from the inner `TextField` — the same
   `FocusNode` instance the screen created, so the assertions are unchanged in
   meaning.
2. **The test harness never gave `SafeArea` a safe area.** `TestWindow` keeps
   `padding` and `viewPadding` in two independent fields; the auth harnesses set
   only `viewPadding`. `SafeArea` reads `padding`, so in tests it consumed
   nothing and content started at y=0 instead of below the status bar. That is
   why `small Android viewport keeps the login card in the safe area` failed
   with `Expected: >= 24, Actual: 7.1e-15`. All three harnesses now set both,
   plus `addTearDown(tester.view.resetPadding)`, exactly as a real device
   reports them.
3. **`dart format` drift on `main`.** Three test files were not formatter-clean,
   which is what turned `main`'s Flutter workflow red. The formatter has been
   run over the whole project; the only change it made to
   `lib/widgets/auth_shell.dart` was one hunk.

### 5.3 One pre-existing layout defect, found by the new tests

`AuthPrimaryButton._content` built `Row(mainAxisSize: min, children:
[Text(label), icon])`. A non-flexible `Text` in a `Row` gets unbounded width, so
when the label is wider than the button the row overflows. On a 360dp viewport
with the Ahem test font that is `A RenderFlex overflowed by 33 pixels on the
right` at `auth_visuals.dart:611` (constraints `0<=w<=218`, wanted 251) — on a
real device the same thing happens at a large text scale.

**Attribution:** a CI baseline run re-ran the pre-existing auth suites with this
branch's `auth_shell.dart` replaced by `main`'s. `reset code focus and value
survive a mobile keyboard inset` still failed, so the overflow is unrelated to
the keyboard fix.

**Fix:** the label became the shrinkable child
(`Flexible(child: Text(label, overflow: TextOverflow.ellipsis))`). At a normal
text scale the row renders pixel-identically; the ellipsis only appears when the
label genuinely cannot fit, which is strictly better than the overflow stripes.

### 5.4 Not run

| step | result |
| --- | --- |
| `flutter build apk --release --dart-define=…` | **NOT RUN** — no Android SDK/JDK in the authoring sandbox, and the repository's CI does not build APKs. |
| Real Android device manual test (§16) | **NOT PERFORMED** — no ADB, no device. |
| Real bug-repro test (§17) on hardware | **NOT PERFORMED** — no ADB, no device. |

The keyboard fix is verified by 323 automated widget tests, two of which are
genuine regression guards that fail against the pre-fix `auth_shell.dart`. It
has **not** been verified on physical hardware; the checklist below is still
outstanding.

### 5.5 Commands and device checklist to run locally

```bash
cd frontend/emergency_app
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --release \
  --dart-define=ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com/api \
  --dart-define=ERAS_GOOGLE_WEB_CLIENT_ID=<configured>
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Watch the screen during the keyboard animation on each step. Expected: the
gradient/grid background never compresses, the brand never moves, the card is
the same card in the same place, no entrance replay, no scroll reset, no
flashing, and the focused field scrolls clear of the keyboard.

LOGIN

1. Open ERAS → tap **Email** → keyboard opens, page does not refresh, the
   email field keeps focus.
2. Type `test@example.com`.
3. Tap **Password** → password focused, email text intact, no layout reset, no
   animation replay.
4. Close the keyboard → smooth return to the original position, no replay.
5. Repeat 1–4 several times.

REGISTER — repeat with Name / Email / Phone / Password / Confirm password;
the selected role card must stay selected and the Login|Register tab must stay
on Register.

FORGOT PASSWORD — repeat with Email, then advance to the code step and repeat
with the 6-digit code, then the new-password step. The step must never reset
back to step 1.

EMAIL VERIFICATION — repeat with the 6-digit code. The code must survive every
keyboard open/close.

Also tap **Continue with Google** on a build where the server answers
`Google sign-in is not configured on this server`: the message must expand in
place without the page looking reloaded.

Tablet / foldable check: with a viewport ≥ 1150 dp wide, focus a field. The
hero illustration, flow strip, status cards and trust card must not move at
all; only the centre card column may scroll.

---

## 6. WHAT IS DELIBERATELY NOT CHANGED

* no visual redesign, no colour/typography/card/branding change;
* no change to the motion language (durations, curves, stagger, reduced-motion
  handling are untouched);
* no change to Firebase bootstrap, Google sign-in, ERAS JWT auth, email
  verification or password reset;
* `PageStorageKey` values are kept (they are still useful for per-screen scroll
  restoration) but are no longer treated as the keyboard fix;
* no custom "scroll the focused field into view" logic was added: the shell
  relies on Flutter's own show-on-screen pass, exactly as before, because the
  scroll viewport is still inset by the keyboard height.
