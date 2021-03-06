////////////////////////////////////////////////////////////////////////////////
//
// Filename:	axiicache.v
//
// Project:	Zip CPU -- a small, lightweight, RISC CPU soft core
//
// Purpose:	An I-Cache, for when the CPU has an AXI interface.
//
// Goal:	To return each instruction within a single clock tick.  Jumps
//		should only stall if they switch cache lines.
//
//	This logic is driven by a couple realities:
//	1. It takes a clock to read from a block RAM address, and hence a clock
//		to read from the cache.
//	2. It takes another clock to check that the tag matches
//
//		Our goal will be to avoid this second check if at all possible.
//		Hence, we'll test on the clock of any given request whether
//		or not the request matches the last tag value, and on the next
//		clock whether it new tag value (if it has changed).  Hence,
//		for anything found within the cache, there will be a one
//		cycle delay on any branch.
//
//
//	Address Words are separated into three components:
//	[ Tag bits ] [ Cache line number ] [ Cache position w/in the line ]
//
//	On any read from the cache, only the second two components are required.
//	On any read from memory, the first two components will be fixed across
//	the bus, and the third component will be adjusted from zero to its
//	maximum value.
//
// For future improvement:
//
//	1. This core only handles one "way".  A future version should extend
//	   this capability to handle a parameterized number of "ways".
//
//	2. For large enough bus widths, it might be necessary to add a clock
//	   to the pipeline in order to select the instruction of interest from
//	   the large (bus-width sized) cache entry.
//
//	3. The core currently only allows invalidating the entire cache.
//	   A possible future improvement might be to allow the CPU to invalidate
//	   specific cache line elements instead--perhaps when/if the CPU writes
//	   to a given address, that address within the instruction cache should
//	   be invalidated.  Perhaps a cache coherency bus protocol could help
//	   here as well.  For the time being, though, cache coherency will be
//	   managed manually by the CPU itself.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2015-2020, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
module	axiicache #(
		// {{{
		// LGCACHESZ is the log(based two) of the cache size *in bytes*
		parameter	LGCACHESZ = 14,
		//
		// LGLINESZ is the size of one cache line, represented in
		// words
		parameter	LGLINESZ=3,
		//
		// LGWAYS is the number of cache "ways"
		parameter	LGWAYS = 0,
		//
		parameter	C_AXI_ID_WIDTH = 1,
		parameter	C_AXI_ADDR_WIDTH = 32,
		parameter	C_AXI_DATA_WIDTH = 32,
		//
		// SWAP_ENDIANNESS
		parameter [0:0]	SWAP_ENDIANNESS = 1'b0,
		//
		parameter	INSN_WIDTH = 32,
		parameter [C_AXI_ID_WIDTH-1:0]	AXI_ID = 0,
		localparam	ADDRLSB = $clog2(C_AXI_DATA_WIDTH/8),
		localparam	LGINSN  = $clog2(INSN_WIDTH/8),
		localparam	INSN_PER_WORD = C_AXI_DATA_WIDTH/INSN_WIDTH,
		localparam	AW=C_AXI_ADDR_WIDTH,
		localparam	DW=C_AXI_DATA_WIDTH
		// }}}
	) (
		// {{{
		input	wire	S_AXI_ACLK,
		input	wire	S_AXI_ARESETN,
		//
		// The AXI Master (cache) interface
		// {{{
		// An instruction cache only needs to support cache reads
		output	wire				M_AXI_ARVALID,
		input	wire				M_AXI_ARREADY,
		output	wire	[C_AXI_ID_WIDTH-1:0]	M_AXI_ARID,
		output	wire	[C_AXI_ADDR_WIDTH-1:0]	M_AXI_ARADDR,
		output	wire	[7:0]			M_AXI_ARLEN,
		output	wire	[2:0]			M_AXI_ARSIZE,
		output	wire	[1:0]			M_AXI_ARBURST,
		output	wire				M_AXI_ARLOCK,
		output	wire	[3:0]			M_AXI_ARCACHE,
		output	wire	[2:0]			M_AXI_ARPROT,
		output	wire	[3:0]			M_AXI_ARQOS,
		//
		input	wire				M_AXI_RVALID,
		output	wire				M_AXI_RREADY,
		input	wire	[C_AXI_ID_WIDTH-1:0]	M_AXI_RID,
		input	wire	[C_AXI_DATA_WIDTH-1:0]	M_AXI_RDATA,
		input	wire				M_AXI_RLAST,
		input	wire	[1:0]			M_AXI_RRESP,
		// }}}
		// CPU interface
		// {{{
		input	wire		i_cpu_reset,
		input	wire		i_new_pc,
		input	wire		i_clear_cache,
		input	wire		i_ready,
		input	wire [AW-1:0]	i_pc,
		output reg [INSN_WIDTH-1:0] o_insn,
		output	reg [AW-1:0]	o_pc,
		output	reg		o_valid,
		output	reg		o_illegal,
		// }}}
		output	wire [AW-1:0]		illegal_addr,
		output	wire [AW-LSB-1:0]	bus_tag,
		output	wire [AW-LSB-1:0]	o_tag,
		output	wire [AW-LSB-1:0]	i_tag,
		output	wire [AW-LSB-1:0]	lastpc_tag
		// }}}
	);

	// Register/local parameter declarations
	// {{{
	localparam CACHELEN=(1<<LGCACHESZ), //Byte Size of our cache memory
			CACHELENW = CACHELEN/(C_AXI_DATA_WIDTH/8); // Word sz
	localparam	CWB=LGCACHESZ, // Short hand for LGCACHESZ
			CW=LGCACHESZ-ADDRLSB; // now in words
	localparam	LS=LGLINESZ, // Size of a cache line in words
			LSB=LGLINESZ+ADDRLSB;
	localparam	LGLINES=CWB-LSB;
	//

	reg	[DW-1:0]	cache		[0:((1<<CW)-1)];
	reg	[(AW-CWB-1):0]	cache_tags	[0:((1<<(LGLINES))-1)];
	reg	[((1<<(LGLINES))-1):0]	cache_valid;
	reg	[DW-1:0]	cache_line;

	reg			last_valid, void_access, from_pc, pc_valid,
				illegal_valid, request_pending, bus_abort,
				valid_line;
	reg	[AW-1:LSB]	pc_tag, last_tag, illegal_tag;
	reg	[LS-1:0]	write_posn;
	reg			axi_arvalid;
	reg	[AW-1:0]	axi_araddr, last_pc;
	reg			start_read;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Check whether or not the instruction requested from the CPU is
	// in the cache or not
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	// void_access
	// {{{
	initial	void_access = 1;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || i_cpu_reset || i_clear_cache)
		void_access <= 1;
	else if (i_new_pc && i_pc[AW-1:LSB] != o_pc[AW-1:LSB])
		void_access <= 1;
	else if (M_AXI_RVALID && M_AXI_RLAST)
		void_access <= 1;
	else
		void_access <= 0;
	// }}}

	// from_pc
	// {{{
	// Whether our next address comes from the just-give program counter
	// from the CPU, or from our own internal measure.  Why?  Because the
	// CPU will move on to the next address on the next cycle, regardless
	// of whether or not we meet this one, therefore we need to latch it
	// for later.
	initial	from_pc = 1;
	always @(posedge S_AXI_ACLK)
	if (i_new_pc || i_clear_cache || (o_valid && i_ready))
		from_pc <= 1;
	else
		from_pc <= 0;
	// }}}

	//
	// From the PC
	// pc_valid
	// {{{
	// True if the cache is valid at the address in the program counter
	always @(posedge S_AXI_ACLK)
		pc_valid <= cache_valid[i_pc[CWB-1:LSB]];
	// }}}

	// pc_tag
	// {{{
	// Evaluates to the cache tag, at the program counter address for the
	// incoming/requested program counter
	always @(posedge S_AXI_ACLK)
		pc_tag <= { cache_tags[i_pc[CWB-1:LSB]], i_pc[CWB-1:LSB] };
	// }}}

	//
	// Repeat for the last program counter--since the current counter
	// will be given only once.  The last_* values will be used any time
	// we have to stall a request before it can be served
	//
	// last_pc
	// {{{
	always @(posedge S_AXI_ACLK)
	if (i_new_pc || (o_valid && i_ready && !o_illegal))
		last_pc <= i_pc;
	// }}}

	// last_valid
	// {{{
	always @(posedge S_AXI_ACLK)
		last_valid <= cache_valid[last_pc[CWB-1:LSB]];
	// }}}

	// last_tag
	// {{{
	always @(posedge S_AXI_ACLK)
		last_tag <={cache_tags[last_pc[CWB-1:LSB]], last_pc[CWB-1:LSB]};
	// }}}

	// valid_line --- are we serving a valid request line?
	// {{{
	always @(*)
	begin
		if (from_pc)
			valid_line = pc_valid && (pc_tag == last_pc[AW-1:LSB]);
		else
			valid_line =last_valid&&(last_tag== last_pc[AW-1:LSB]);
		if (illegal_valid && illegal_tag == last_pc[AW-1:LSB])
			valid_line = 1;
		if (void_access)
			valid_line = 0;
	end
	// }}}

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Request data from the AXI bus to fill a cache miss
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// start_read
	// {{{
	// Issue a bus transaction -- the cache line requested couldn't be
	// found in the bus anywhere, so we need to go look for it
	always @(*)
	begin
		start_read = !valid_line && !o_valid;
		if (i_clear_cache || i_new_pc || void_access)
			start_read = 0;
		if (o_illegal)
			start_read = 0;
		if (M_AXI_ARVALID)
			start_read = 0;
		if (request_pending || i_cpu_reset || !S_AXI_ARESETN)
			start_read = 0;
	end
	// }}}

	// axi_arvalid
	// {{{
	initial	axi_arvalid = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		axi_arvalid <= 0;
	else if (!M_AXI_ARVALID || M_AXI_ARREADY)
		axi_arvalid <= start_read;
	// }}}

	// request_pending, bus_abort
	// {{{
	initial	request_pending = 0;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
	begin
		request_pending <= 0;
		bus_abort <= 0;
	end else if (request_pending)
	begin
		if (i_cpu_reset || i_clear_cache)
			bus_abort <= 1;
		if (M_AXI_RVALID && M_AXI_RRESP[1])
			bus_abort <= 1;
		if (i_new_pc && i_pc[AW-1:LSB] != axi_araddr[AW-1:LSB])
			bus_abort <= 1;

		if (M_AXI_RVALID && M_AXI_RLAST)
		begin
			request_pending <= 0;
			bus_abort <= 0;
		end
	end else if (!M_AXI_ARVALID || M_AXI_ARREADY)
	begin
		request_pending <= start_read;
		bus_abort <= 0;
	end
	// }}}

	// axi_araddr
	// {{{
	always @(posedge S_AXI_ACLK)
	if ((!M_AXI_ARVALID || M_AXI_ARREADY) && !request_pending)
	begin
		axi_araddr <= last_pc;
		axi_araddr[LSB-1:0] <= 0;
	end
	// }}}

	// }}}
	/////////////////////////////////////////////////
	//
	// Fill the cache with the new data
	// {{{
	/////////////////////////////////////////////////
	//
	//

	// write_posn -- the sub-address w/in the cache to write to
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!request_pending)
		write_posn <= 0;
	else if (M_AXI_RVALID && M_AXI_RREADY)
		write_posn <= write_posn + 1;
	// }}}

	// cache -- Actually do the write to cache memory
	// {{{
	generate if (SWAP_ENDIANNESS)
	begin : BIG_TO_LITTLE_ENDIAN
		// {{{
		// 
		// The ZipCPU is originally a big endian machine.  Bytes on the
		// AXI bus are by nature little endian.  The following little
		// snippet rearranges bytes so that they have the proper bus
		// order.  Whether or not this is required, however, is ...
		// another issue entirely.
		reg	[C_AXI_DATA_WIDTH-1:0]	swapped_data;
		genvar	gw, gb;	// Word count, byte count

		for(gw=0; gw<C_AXI_DATA_WIDTH/32; gw=gw+1)
		for(gb=0; gb<4; gb=gb+1)
		always @(*)
			swapped_data[gw*32+(3-gb)*8 +: 8]
					= M_AXI_RDATA[gw*32+gb*8 +: 8];

		always @(posedge S_AXI_ACLK)
		if (M_AXI_RVALID && M_AXI_RREADY)
			cache[{ axi_araddr[CWB-1:LSB], write_posn }]
							<= swapped_data;
		// }}}
	end else begin : KEEP_ENDIANNESS
		// {{{
		always @(posedge S_AXI_ACLK)
		if (M_AXI_RVALID && M_AXI_RREADY)
			cache[{ axi_araddr[CWB-1:LSB], write_posn }]
							<= M_AXI_RDATA;
		// }}}
	end endgenerate
	// }}}

	// cache_tags, set/control/write-to the cache tags array
	// {{{
	always @(posedge S_AXI_ACLK)
	if (request_pending)
		cache_tags[axi_araddr[CWB-1:LSB]] <= axi_araddr[AW-1:CWB];
	// }}}

	// cache_valid--keep track of which cache entry has valid data w/in it
	// {{{
	initial	cache_valid = 0;
	always @(posedge S_AXI_ACLK)
	if (i_cpu_reset || i_clear_cache)
		cache_valid <= 0;
	else if (request_pending)
		cache_valid[axi_araddr[CWB-1:LSB]]
			<= (M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST
				&& !M_AXI_RRESP[1] && !bus_abort);
	// }}}

	// }}}
	/////////////////////////////////////////////////
	//
	// Read the instruction from the cache
	// {{{
	/////////////////////////////////////////////////
	//
	//

	// cache_line -- the line number of the address requested
	// {{{
	always @(posedge S_AXI_ACLK)
	if (i_new_pc || (!o_valid || i_ready))
	begin
		cache_line <= cache[(i_new_pc || o_valid)
				? i_pc[CWB-1:ADDRLSB] : o_pc[CWB-1:ADDRLSB]];
	end
	// }}}

	// o_insn
	// {{{
	// Generate the outgoing instruction from the given cache_line
	// This involves shifting large cache words down to the desired/correct
	// word of interest
	generate if (C_AXI_DATA_WIDTH == INSN_WIDTH)
	begin : NO_LINE_SHIFT

		always @(*)
			o_insn = cache_line;

	end else begin

		reg	[C_AXI_DATA_WIDTH-1:0]	shifted;

		always @(*)
		begin
			shifted=cache_line >> (INSN_WIDTH * o_pc[LSB-1:LGINSN]);
			o_insn = shifted[DW-1:0];
		end
	end endgenerate
	// }}}

	// o_pc
	// {{{
	// Signal the CPU with the actual address of the value we are returning
	// The ffetch properties will insure this value is correct.  This CPU
	// then uses it for knowing the program counter of the instruction
	// contained within each stage of the pipeline
	initial	o_pc = 0;
	always @(posedge S_AXI_ACLK)
	if (i_new_pc)
		o_pc <= i_pc;
	else if (o_valid && i_ready)
	begin
		o_pc[AW-1:2] <= o_pc[AW-1:2]+1;
		o_pc[1:0]    <= 0;
	end
	// }}}

	// o_valid
	// {{{
	// Are we returning a valid instruction to the CPU on this cycle?
	initial	o_valid = 0;
	always @(posedge S_AXI_ACLK)
	if (i_cpu_reset || i_clear_cache)
		o_valid <= 0;
	else if (o_valid && (i_ready || i_new_pc))
	begin
		// Grab the next instruction--always ready on the same cycle
		// if we stay within the same cache line
		o_valid <= (i_pc[AW-1:LSB] == o_pc[AW-1:LSB]);
		if (o_illegal)
			o_valid <= 0;
		if (!valid_line)
			o_valid <= 0;
	end else if (!o_valid && !i_new_pc)
	begin
		// We're stuck waiting for the cache line to become valid.
		// Don't forget to check for the illegal flag.
		o_valid <= valid_line;
		if (illegal_valid && o_pc[AW-1:LSB] == illegal_tag)
			o_valid <= 1;
	end
	// }}}

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Handle bus errors here.
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	// If a bus read request returns an error, then we'll mark the entire
	// line as having a (valid) illegal value.  Once the o_illegal value
	// is set, it will remain set until either the CPU branches, or the
	// cache is cleared.
	//

	// illegal_tag, illegal_valid
	// {{{
	// Here's the rule: if illegal_valid is true, then we know that address
	// at that illegal_tag value will produce a bus error, and we can serve
	// a bus error request response on any read request.
	initial	illegal_tag = 0;
	initial	illegal_valid = 0;
	always @(posedge S_AXI_ACLK)
	if ((i_cpu_reset)||(i_clear_cache))
	begin
		illegal_tag <= 0;
		illegal_valid <= 0;
	end else if (M_AXI_RVALID && M_AXI_RRESP[1])
	begin
		illegal_tag <= axi_araddr[AW-1:LSB];
		illegal_valid <= 1'b1;
	end
	// }}}

	// o_illegal
	// {{{
	initial o_illegal = 1'b0;
	always @(posedge S_AXI_ACLK)
	if (i_cpu_reset || i_clear_cache || i_new_pc)
		o_illegal <= 1'b0;
	else if (o_valid && !o_illegal)
		o_illegal <= 1'b0;
	else if (illegal_valid && o_pc[AW-1:LSB] == illegal_tag)
		o_illegal <= 1'b1;
	// }}}
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Fixed/constant bus values, map registers to AXI wires/ etc.
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// Fixed bus outputs: we read from the bus only, never write.
	// Thus the output data is ... irrelevant and don't care.  We set it
	// to zero just to set it to something.
	assign	M_AXI_ARVALID= axi_arvalid;
	assign	M_AXI_ARID   = AXI_ID;
	assign	M_AXI_ARADDR = axi_araddr;
	assign	M_AXI_ARLEN  = (1<<LGLINESZ)-1;
	assign	M_AXI_ARSIZE = ADDRLSB[2:0];
	// ARBURST.  AXI supports a WRAP burst specifically for the purpose
	// of a CPU.  Not all peripherals support it.  For compatibility and
	// simplicities sake, we'll just use INCR here.
	assign	M_AXI_ARBURST= 2'b01; // INCR
	assign	M_AXI_ARLOCK = 0;
	assign	M_AXI_ARCACHE= 4'b0011;
	// ARPROT = 3'b100 for an unprivileged, secure instruction access
	// (not sure what unprivileged or secure mean--even after reading the
	//  spec)
	assign	M_AXI_ARPROT = 3'b100;
	assign	M_AXI_ARQOS  = 4'h0;
	assign	M_AXI_RREADY = 1'b1;
	// }}}

	// Make Verilator happy
	// {{{
	// Verilator lint_off UNUSED
	wire	unused;
	assign	unused = &{ 1'b0, M_AXI_RID, M_AXI_RRESP[0] };
	// Verilator lint_on  UNUSED
	// }}}
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal property section
// {{{
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	////////////////////////////////////////////////////////////////////////
	//
	// The following are a *subset* of the formal properties used to verify
	// this instruction cache
	//
	////////////////////////////////////////////////////////////////////////
	//
	//
	reg	f_past_valid;
	reg	[4:0]	f_cpu_delay;
	reg	[((1<<(LGLINES))-1):0]	f_past_valid_mask;
	reg	[(AW+1):0]	f_next_pc;
	reg [AW+1:0]	f_next_lastpc;
	reg	[AW-1:0]		f_cklast;


	// Keep track of a flag telling us whether or not $past()
	// will return valid results
	initial	f_past_valid = 1'b0;
	always @(posedge S_AXI_ACLK)
		f_past_valid = 1'b1;

	always @(*)
	if (!S_AXI_ARESETN)
		assume(i_cpu_reset);

	////////////////////////////////////////////////////////////////////////
	//
	// Assumptions about our inputs
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	wire	[AW-1:0]	f_const_addr, f_address;
	wire			f_const_illegal;
	wire [INSN_WIDTH-1:0]	f_const_insn;

	//
	// Assume/assert the properties of the PF <-> CPU interface
	//
	ffetch #(.ADDRESS_WIDTH(AW-LGINSN))
	fcpu(.i_clk(S_AXI_ACLK), .i_reset(i_cpu_reset),
		.cpu_new_pc(i_new_pc), .cpu_clear_cache(i_clear_cache),
		.cpu_pc(i_pc), .cpu_ready(i_ready), .pf_valid(o_valid),
		.pf_insn(o_insn), .pf_pc(o_pc), .pf_illegal(o_illegal),
		.fc_pc(f_const_addr), .fc_illegal(f_const_illegal),
		.fc_insn(f_const_insn), .f_address(f_address));

	always @(*)
	if (!i_cpu_reset && !i_new_pc && !i_clear_cache)
		assert(o_pc == f_address);

	//
	// Let's make some assumptions about how long it takes our
	// phantom bus and phantom CPU to respond.
	//
	// These delays need to be long enough to flush out any potential
	// errors, yet still short enough that the formal method doesn't
	// take forever to solve.
	//
	localparam	F_CPU_DELAY = 4;


	// Now, let's repeat this bit but now looking at the delay the CPU
	// takes to accept an instruction.
	always @(posedge S_AXI_ACLK)
	// If no instruction is ready, then keep our counter at zero
	if ((!o_valid)||(i_ready))
		f_cpu_delay <= 0;
	else
		// Otherwise, count the clocks the CPU takes to respond
		f_cpu_delay <= f_cpu_delay + 1'b1;

	always @(posedge S_AXI_ACLK)
		assume(f_cpu_delay < F_CPU_DELAY);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Formal AXI bus properties
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	localparam	F_LGDEPTH=12;

	wire	M_AXI_AWREADY, M_AXI_WREADY, M_AXI_BVALID;
	wire	[C_AXI_ID_WIDTH-1:0]	M_AXI_BID;
	wire	[1:0]			M_AXI_BRESP;

	//
	// ...
	//

	faxi_master #(
		// {{{
		.C_AXI_ID_WIDTH(C_AXI_ID_WIDTH),
		.C_AXI_ADDR_WIDTH(C_AXI_ADDR_WIDTH),
		.C_AXI_DATA_WIDTH(C_AXI_DATA_WIDTH),
		.OPT_NARROW_BURST(1'b0),
		.OPT_ASYNC_RESET(1'b0),	// We don't use asynchronous resets
		.OPT_EXCLUSIVE(1'b0),	// We don't use the LOCK signal
		.F_OPT_ASSUME_RESET(1'b1), // We aren't generating the reset
		.F_OPT_NO_RESET(1'b1),
		.F_LGDEPTH(F_LGDEPTH)	// Width of the counters
		// }}}
	) faxi(
		// {{{
		.i_clk(S_AXI_ACLK), .i_axi_reset_n(S_AXI_ARESETN),
		// Write signals
		// {{{
		.i_axi_awvalid(1'b0),
		.i_axi_awready(M_AXI_AWREADY),
		.i_axi_awid(   M_AXI_ARID),
		.i_axi_awaddr( M_AXI_ARADDR),
		.i_axi_awlen(  M_AXI_ARLEN),
		.i_axi_awsize( M_AXI_ARSIZE),
		.i_axi_awburst(M_AXI_ARBURST),
		.i_axi_awlock( M_AXI_ARLOCK),
		.i_axi_awcache(M_AXI_ARCACHE),
		.i_axi_awprot( M_AXI_ARPROT),
		.i_axi_awqos(  M_AXI_ARQOS),
		//
		.i_axi_wvalid(1'b0),
		.i_axi_wready(M_AXI_WREADY),
		.i_axi_wdata( {(C_AXI_DATA_WIDTH  ){1'b0}}),
		.i_axi_wstrb( {(C_AXI_DATA_WIDTH/8){1'b0}}),
		.i_axi_wlast( 1'b0),
		//
		.i_axi_bvalid(M_AXI_BVALID),
		.i_axi_bready(1'b1),
		.i_axi_bid(   M_AXI_BID),
		.i_axi_bresp( M_AXI_BRESP),
		// }}}
		// Read signals
		// {{{
		.i_axi_arvalid(M_AXI_ARVALID),
		.i_axi_arready(M_AXI_ARREADY),
		.i_axi_arid(   M_AXI_ARID),
		.i_axi_araddr( M_AXI_ARADDR),
		.i_axi_arlen(  M_AXI_ARLEN),
		.i_axi_arsize( M_AXI_ARSIZE),
		.i_axi_arburst(M_AXI_ARBURST),
		.i_axi_arlock( M_AXI_ARLOCK),
		.i_axi_arcache(M_AXI_ARCACHE),
		.i_axi_arprot( M_AXI_ARPROT),
		.i_axi_arqos(  M_AXI_ARQOS),
		//
		//
		.i_axi_rvalid(M_AXI_RVALID),
		.i_axi_rready(M_AXI_RREADY),
		.i_axi_rid(   M_AXI_RID),
		.i_axi_rdata( M_AXI_RDATA),
		.i_axi_rlast( M_AXI_RLAST),
		.i_axi_rresp( M_AXI_RRESP)
		// }}}
		// }}}
	);

	//
	// ...
	//

	reg	[AW-1:0]	next_addr;
	always @(*)
	begin
		next_addr = o_pc + (1<<LGINSN);
		next_addr[LGINSN-1:0] = 0;
	end

	always @(*)
	if (!i_cpu_reset && !i_new_pc && !i_clear_cache && !o_illegal)
		assert(last_pc == o_pc);

	always @(*)
	if (!i_cpu_reset && !i_new_pc && !i_clear_cache)
		assert(next_addr == i_pc);


	assign	illegal_addr = { illegal_tag, {(LSB){1'b0}} };
	assign	bus_tag = axi_araddr[AW-1:LSB];
	assign	o_tag   = o_pc[AW-1:LSB];
	assign	i_tag   = i_pc[AW-1:LSB];
	assign	lastpc_tag= last_pc[AW-1:LSB];

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Assertions about our return responses to the CPU
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge S_AXI_ACLK)
	if (f_past_valid && $past(i_clear_cache || i_cpu_reset))
	begin
		assert(cache_valid == 0);
		assert(!o_valid);
		assert(!illegal_valid);
		assert(void_access);
	end
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Contract checking
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	(* anyconst *)	reg	[DW-1:0]	fc_line;

	//
	// 1. Assume a known response to a known address
	// {{{
	generate if (INSN_WIDTH == C_AXI_DATA_WIDTH)
	begin
		always @(*)
			assume(fc_line == f_const_insn);

	end else begin : SHIFT_FC_LINE
		reg	[DW-1:0]	shifted_line;

		always @(*)
			shifted_line = fc_line >> (INSN_WIDTH * f_const_addr[ADDRLSB-1:LGINSN]);
		always @(*)
			assume(shifted_line[INSN_WIDTH-1:0] == f_const_insn);

	end endgenerate

	always @(*)
	if (M_AXI_RVALID && axi_araddr[AW-1:LSB] == f_const_addr[AW-1:LSB])
		assume(f_const_illegal == M_AXI_RRESP[1]);

	generate if (SWAP_ENDIANNESS)
	begin : ASSUME_BIG_TO_LITTLE_ENDIAN

		always @(*)
		if (M_AXI_RVALID && {axi_araddr[AW-1:LSB], write_posn} == f_const_addr[AW-1:ADDRLSB])
		begin
			if (!M_AXI_RRESP[1])
				assume(BIG_TO_LITTLE_ENDIAN.swapped_data
								== fc_line);
		end

	end else begin : ASSUME_BUS_ENDIAN

		always @(*)
		if (M_AXI_RVALID && {axi_araddr[AW-1:LSB], write_posn} == f_const_addr[AW-1:ADDRLSB])
		begin
			if (!M_AXI_RRESP[1])
				assume(M_AXI_RDATA == fc_line);
		end

	end endgenerate
	// }}}

	//
	// 2. Assert that if the known address is in the cache, the data must be
	//	the correct data
	// {{{
	always @(*)
	if (cache_valid[f_const_addr[CWB-1:LSB]]
			&& cache_tags[f_const_addr[CWB-1:LSB]]
						== f_const_addr[AW-1:CWB])
		assert(cache[f_const_addr[CWB-1:ADDRLSB]] == fc_line);

	always @(*)
	if (f_const_illegal)
		assert(!cache_valid[f_const_addr[CWB-1:LSB]]
			|| cache_tags[f_const_addr[CWB-1:LSB]]
						!= f_const_addr[AW-1:CWB]);
	else
		assert(!illegal_valid || illegal_tag != f_const_addr[AW-1:LSB]);

	//
	// Anything else in a line with one illegal element must also be illegal
	always @(*)
	if (o_valid && o_pc[AW-1:LSB] == f_const_addr[AW-1:LSB]
			&& f_const_illegal)
		assert(o_illegal);
	// }}}

	//
	// 3. If our chosen address is ever returned, assert that it contains
	//	the correct data and illegal flag within it
	// {{{

	// Captured inside ffetch above

	// }}}
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Cover properties
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	reg	f_valid_legal;
	reg	[3:0]	cvr_valids;

	always @(*)
		f_valid_legal = o_valid && (!o_illegal);

	initial	cvr_valids = 0;
	always @(posedge S_AXI_ACLK)
	if (i_cpu_reset || i_clear_cache || i_new_pc || o_illegal)
		cvr_valids <= 0;
	else if (o_valid && i_ready && !cvr_valids[3])
		cvr_valids <= cvr_valids + 1;

	always @(posedge S_AXI_ACLK)		// Trace 0
		cover((o_valid)&&( o_illegal));
	always @(posedge S_AXI_ACLK)		// Trace 1
		cover(f_valid_legal);
	always @(posedge S_AXI_ACLK)		// Trace 2
		cover((f_valid_legal)
			&&($past(!o_valid && !i_new_pc))
			&&($past(i_new_pc,2)));
	always @(posedge S_AXI_ACLK)		// Trace 3
		cover((f_valid_legal)&&($past(i_ready))&&($past(i_new_pc)));
	always @(posedge S_AXI_ACLK)		// Trace 4
		cover((f_valid_legal)&&($past(f_valid_legal && i_ready)));
	always @(posedge S_AXI_ACLK)		// Trace 5
		cover((f_valid_legal)
			&&($past(f_valid_legal && i_ready))
			&&($past(f_valid_legal && i_ready,2))
			&&($past(f_valid_legal && i_ready,3)));
	always @(posedge S_AXI_ACLK)		// Trace 6
		cover((f_valid_legal)
			&&($past(f_valid_legal && i_ready))
			&&($past(f_valid_legal && i_ready,2))
			&&($past(!o_illegal && i_ready && i_new_pc,3))
			&&($past(f_valid_legal && i_ready,4))
			&&($past(f_valid_legal && i_ready,5))
			&&($past(f_valid_legal && i_ready,6)));

	always @(*)
	begin
		cover(cvr_valids == 4'b0100);
		cover(cvr_valids == 4'b0101);
		cover(cvr_valids == 4'b0110);	// Takes about 20 minutes
	end

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Illegal instruction checks
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	(* anyconst *)	reg	f_never_illegal, f_always_illegal;
	always @(*)
		assume(!f_never_illegal || !f_always_illegal);

	always @(*)
	if (M_AXI_RVALID)
	begin
		assume(!f_never_illegal  || !M_AXI_RRESP[1]);
		assume(!f_always_illegal ||  M_AXI_RRESP[1]);
	end

	always @(*)
	if (f_always_illegal && o_valid)
		assert(o_illegal);
	
	always @(*)
	if (f_always_illegal)
		assert(cache_valid == 0);

	always @(*)
	if (f_never_illegal)
		assert(!illegal_valid);

	always @(*)
	if (f_never_illegal)
		assert(!o_illegal);
	// }}}
	
	////////////////////////////////////////////////////////////////////////
	//
	// Constraining assumptions
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// None currently

	// }}}	
`endif	// FORMAL
// }}}
endmodule
