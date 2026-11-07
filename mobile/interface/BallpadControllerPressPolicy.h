#pragma once

constexpr bool BallpadShouldSuppressControllerPress(bool hasHardwareKey,
                                                    bool handlesController,
                                                    bool presentingInterface) noexcept {
    return !hasHardwareKey && handlesController && !presentingInterface;
}
