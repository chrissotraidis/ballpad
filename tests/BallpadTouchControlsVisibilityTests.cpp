// Touch-control auto-hide against the controller bridge's real slot table.
#include "../mobile/interface/BallpadTouchControlsVisibility.h"

#include <cassert>
#include <iostream>

namespace {

constexpr uintptr_t kNoScript = 0;

bool Hidden(const SunPadControllerSlots& slots, bool autoHide, bool editing = false,
            uintptr_t scripted = kNoScript) {
  return BallpadTouchControlsHidden(editing, autoHide,
                                    BallpadTouchPlayerHasController(slots, scripted));
}

}  // namespace

int main() {
  constexpr uintptr_t first = 0x1001;
  constexpr uintptr_t second = 0x2001;
  constexpr uintptr_t scripted = 0x3001;

  // No controller: visible whatever the preference.
  SunPadControllerSlots slots;
  assert(!Hidden(slots, true));

  // A pad already connected at launch is assigned by the bridge's first reconcile and hides the
  // controls while auto-hide is on.
  slots.Reconcile({first});
  assert(Hidden(slots, true));

  // Auto-hide off (the setting, or Show Touch Controls) shows them with the pad still connected;
  // back on hides them again. The editor always shows them.
  assert(!Hidden(slots, false));
  assert(Hidden(slots, true));
  assert(!Hidden(slots, true, true));

  // Removing the second of two pads keeps the touch player's pad, so the controls stay hidden.
  slots.Reconcile({first, second});
  slots.Reconcile({first});
  assert(Hidden(slots, true));

  // A pad left only in slot 2 belongs to a port the game does not read; touch is player 1's input.
  slots.Reconcile({first, second});
  slots.Reconcile({second});
  assert(!Hidden(slots, true));

  // Disconnecting everything shows the controls.
  slots.Reconcile({});
  assert(!Hidden(slots, true));

  // The app's own scripted GCVirtualController in slot 0 is not a physical pad.
  SunPadControllerSlots scriptedSlots;
  scriptedSlots.Reconcile({scripted});
  assert(!Hidden(scriptedSlots, true, false, scripted));

  std::cout << "Ballpad touch-control visibility tests passed\n";
  return 0;
}
