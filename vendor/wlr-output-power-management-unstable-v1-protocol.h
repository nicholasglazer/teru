/**
 * Shim for wlroots' wlr_output_power_management_v1.h.
 *
 * wlroots 0.18 as shipped on Arch (and most distros) includes the
 * *header* wlr_output_power_management_v1.h but NOT the generated
 * protocol header it #includes ("wlr-output-power-management-
 * unstable-v1-protocol.h" — produced by wayland-scanner from the XML
 * at wlroots build time and kept internal to wlroots' build tree).
 *
 * The protocol header's entire contribution to our glue file is one
 * enum. Per the upstream XML (wlr-protocols/wlr-output-power-
 * management-unstable-v1.xml, stable since 2019), the mode values are:
 *    off = 0
 *    on  = 1
 *
 * We declare just the enum so including wlroots' public header from
 * miozu-wlr-glue.c resolves without pulling in the unavailable
 * generated header. No XML → wayland-scanner dependency required.
 */
#ifndef MIOZU_WLR_OUTPUT_POWER_MANAGEMENT_UNSTABLE_V1_PROTOCOL_H
#define MIOZU_WLR_OUTPUT_POWER_MANAGEMENT_UNSTABLE_V1_PROTOCOL_H

enum zwlr_output_power_v1_mode {
    ZWLR_OUTPUT_POWER_V1_MODE_OFF = 0,
    ZWLR_OUTPUT_POWER_V1_MODE_ON  = 1,
};

#endif
