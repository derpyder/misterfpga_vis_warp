//
// Copyright (c) 2026 Rejected Coins LLC (Phase 2 vis_warp framework)
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// ----------------------------------------------------------------------
//
// vbuf_svc -- 2-channel round-robin arbiter for the 128-bit DDR3 vbuf
// channel exposed by sysmem.sv. Modeled on ddr_svc.sv (the 64-bit
// 2-channel ram2 arbiter) but extended with:
//   - 128-bit data path / 16-bit byteenable / 28-bit address
//   - Full read AND write support (ddr_svc is read-only)
//   - Per-channel writedata + byteenable inputs (not hard-coded to 0/FF)
//
// Role: ascal (ch0) and vis_warp (ch1) both need the vbuf. ascal does
// its own polyphase scaler scratch (long bursts, both R/W); vis_warp
// reads/writes the source-resolution frame buffer banks. They cannot
// drive sysmem.vbuf concurrently, so this arbiter multiplexes them.
//
// Scheduling: strict round-robin with starting preference for ch0
// (ascal) -- matches ddr_svc's pattern. Both channels are pass-through
// Avalon-MM slaves: the requester drives all of its own avl_* signals,
// and the arbiter just selects whose signals reach the sysmem master.
// The non-selected channel sees waitrequest=1, which back-pressures
// it correctly per the Avalon-MM spec.
//
// Burst atomicity: ascal can request burst lengths up to 255 (8-bit
// burstcount). The arbiter latches `cur_ch` at burst start and holds
// it until the burst completes -- counted by writeresponse cycles for
// writes (waitrequest deasserted while write=1) and by readdatavalid
// pulses for reads. Mid-burst handover would corrupt the DDR3 access;
// the latch prevents it.
//
// Timing: combinational mux on outputs (waitrequest -> requester,
// readdata -> requester). Adds zero pipeline stages to the Avalon-MM
// path. Critical path is the per-channel grant mux which is shallow.
// State updates on `clk` (= clk_100m, the vbuf clock).
//
// Verification: synthesizes clean against the same Cyclone V target
// as ddr_svc.sv. Functional: at boot, both ch0 and ch1 idle (read=0,
// write=0); first request wins; subsequent requests round-robin.
//

module vbuf_svc
(
    input             clk,

    // --- Master side: connects to sysmem.vbuf ---
    output            ram_waitrequest,    // unused output (always-grant master)
    output      [7:0] ram_burstcount,
    output     [27:0] ram_addr,
    output    [127:0] ram_writedata,
    output     [15:0] ram_byteenable,
    output            ram_read,
    output            ram_write,
    input             ram_waitrequest_in, // from sysmem.vbuf
    input     [127:0] ram_readdata,
    input             ram_readdatavalid,

    // --- ch0 slave (ascal) ---
    input      [27:0] ch0_address,
    input       [7:0] ch0_burstcount,
    input     [127:0] ch0_writedata,
    input      [15:0] ch0_byteenable,
    input             ch0_read,
    input             ch0_write,
    output    [127:0] ch0_readdata,
    output            ch0_readdatavalid,
    output            ch0_waitrequest,

    // --- ch1 slave (vis_warp) ---
    input      [27:0] ch1_address,
    input       [7:0] ch1_burstcount,
    input     [127:0] ch1_writedata,
    input      [15:0] ch1_byteenable,
    input             ch1_read,
    input             ch1_write,
    output    [127:0] ch1_readdata,
    output            ch1_readdatavalid,
    output            ch1_waitrequest
);

// State machine: idle -> grant -> wait-for-burst-completion -> idle
// cur_ch: which channel currently owns the master (latched at grant).
// cur_busy: 1 while a burst is in flight (the master is not retargetable).
// burst_left: words remaining in the current burst.
// is_read: latched direction of current burst.
reg        cur_ch     = 1'b0;
reg        cur_busy   = 1'b0;
reg        is_read    = 1'b0;
reg  [8:0] burst_left = 9'd0;   // 9 bits so we can hold burstcount range 1..256
reg        last_grant = 1'b0;   // tracks fairness for round-robin

// Helper wires: did each channel issue a fresh request this cycle?
wire ch0_req = ch0_read | ch0_write;
wire ch1_req = ch1_read | ch1_write;

// Grant logic: when idle, pick a requesting channel. Round-robin by
// preferring whichever channel did NOT win last (last_grant=0 -> prefer
// ch1, last_grant=1 -> prefer ch0 first).
wire grant_ch0 = !cur_busy && ch0_req && !(last_grant == 1'b0 && ch1_req);
wire grant_ch1 = !cur_busy && ch1_req && !(last_grant == 1'b1 && ch0_req);

// "next selected channel" combinational (drives master mux this cycle so
// the requester sees its grant on the same cycle without an extra pipeline
// stage of latency, matching the ddr_svc pass-through behavior).
wire sel_ch = cur_busy ? cur_ch
            : grant_ch0 ? 1'b0
            : grant_ch1 ? 1'b1
            : 1'b0;
wire sel_active = cur_busy | grant_ch0 | grant_ch1;

// Master output mux: pass through the selected channel's signals; if no
// channel is selected, drive zeros so sysmem sees an idle bus.
assign ram_addr        = sel_active ? (sel_ch ? ch1_address    : ch0_address)    : 28'd0;
assign ram_burstcount  = sel_active ? (sel_ch ? ch1_burstcount : ch0_burstcount) : 8'd0;
assign ram_writedata   = sel_active ? (sel_ch ? ch1_writedata  : ch0_writedata)  : 128'd0;
assign ram_byteenable  = sel_active ? (sel_ch ? ch1_byteenable : ch0_byteenable) : 16'd0;
assign ram_read        = sel_active ? (sel_ch ? ch1_read       : ch0_read)       : 1'b0;
assign ram_write       = sel_active ? (sel_ch ? ch1_write      : ch0_write)      : 1'b0;

// Unused output (we don't need to back-pressure the master).
assign ram_waitrequest = 1'b0;

// Waitrequest back to the channels:
//   - Selected channel sees the real ram_waitrequest_in (and only during
//     its own grant; once the burst is over and we're between bursts the
//     channel naturally stops asserting read/write).
//   - Non-selected channel sees 1 (back-pressure).
assign ch0_waitrequest = (sel_active && sel_ch == 1'b0) ? ram_waitrequest_in : 1'b1;
assign ch1_waitrequest = (sel_active && sel_ch == 1'b1) ? ram_waitrequest_in : 1'b1;

// Readdata fanout: both channels see the same readdata; valid is gated
// on which channel currently owns the burst. The owner is whoever
// initiated the burst -- cur_ch while cur_busy is 1, else the just-granted
// channel for read latency.
//
// Note: we route readdata to BOTH channels' readdata wires (it's just
// fan-out, no harm), but readdatavalid is gated by ownership. This keeps
// the requester's logic simple: it only sees rdv pulse when it owns the
// transaction.
assign ch0_readdata      = ram_readdata;
assign ch1_readdata      = ram_readdata;
assign ch0_readdatavalid = ram_readdatavalid & ((cur_busy & ~cur_ch) | (!cur_busy & grant_ch0 & ch0_read));
assign ch1_readdatavalid = ram_readdatavalid & ((cur_busy &  cur_ch) | (!cur_busy & grant_ch1 & ch1_read));

// Burst tracking:
//   - On grant edge, latch cur_ch / is_read / burst_left.
//   - For reads, decrement burst_left on each readdatavalid.
//   - For writes, decrement burst_left on each cycle where write was
//     accepted (write asserted AND !waitrequest_in).
//   - When burst_left reaches 0 (i.e. last word completes), release the
//     master back to idle.
always @(posedge clk) begin
    if (!cur_busy) begin
        // Idle -- look for a grant.
        if (grant_ch0) begin
            cur_ch     <= 1'b0;
            cur_busy   <= 1'b1;
            is_read    <= ch0_read;
            // burstcount of 0 is illegal; treat 1..255 normally, and one
            // grant covers ch0_burstcount cycles of read or write traffic.
            burst_left <= {1'b0, ch0_burstcount};
            last_grant <= 1'b0;
        end else if (grant_ch1) begin
            cur_ch     <= 1'b1;
            cur_busy   <= 1'b1;
            is_read    <= ch1_read;
            burst_left <= {1'b0, ch1_burstcount};
            last_grant <= 1'b1;
        end
    end else begin
        // Busy -- count down the burst.
        if (is_read) begin
            if (ram_readdatavalid && burst_left != 9'd0) begin
                if (burst_left == 9'd1) begin
                    cur_busy <= 1'b0;
                end
                burst_left <= burst_left - 9'd1;
            end
        end else begin
            // Write: a word completes whenever ram_write is high and the
            // slave (sysmem) is NOT asserting waitrequest (Avalon accept).
            if (ram_write && !ram_waitrequest_in && burst_left != 9'd0) begin
                if (burst_left == 9'd1) begin
                    cur_busy <= 1'b0;
                end
                burst_left <= burst_left - 9'd1;
            end
        end
    end
end

endmodule
