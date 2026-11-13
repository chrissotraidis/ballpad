// When the touch controls give way to a physical controller. No Apple types, so the rule can be
// checked on its own (tests/BallpadTouchControlsVisibilityTests.cpp) against the same slot table the
// controller bridge keeps.

#ifndef BALLPAD_TOUCH_CONTROLS_VISIBILITY_H
#define BALLPAD_TOUCH_CONTROLS_VISIBILITY_H

#include <cstdint>

#include "SunPadControllerSlots.h"

// Touch drives port 0, and the bridge offers only slot 0 to the game, so only a controller in
// slot 0 stands in for the touch controls; a pad in a later slot never hides them. The scripted
// controller is the app's own GCVirtualController and never counts as a physical pad.
inline bool BallpadTouchPlayerHasController(const SunPadControllerSlots& slots,
                                            uintptr_t appVirtualController) {
  const uintptr_t owner = slots.InstanceAt(0);
  return owner != 0 && owner != appVirtualController;
}

// Layout editing always shows the controls so it stays escapable. Otherwise auto-hide hides them
// while the touch player has a controller. "Show Touch Controls" turns auto-hide off, so this
// returns false with the controller still connected.
inline bool BallpadTouchControlsHidden(bool editingLayout, bool autoHideWithController,
                                       bool touchPlayerHasController) {
  return !editingLayout && autoHideWithController && touchPlayerHasController;
}

#endif  // BALLPAD_TOUCH_CONTROLS_VISIBILITY_H
