//! Optional debugger state grouped behind one evaluator component.

pub fn State(comptime Ui: type, comptime BreakpointTable: type) type {
    return struct {
        ui: ?Ui = null,
        in_session: bool = false,
        breakpoints: ?BreakpointTable = null,
        source: ?[]const u8 = null,

        pub fn setUi(self: *@This(), ui: Ui) void {
            self.ui = ui;
        }

        pub fn setSource(self: *@This(), source: ?[]const u8) void {
            self.source = source;
        }

        pub fn beginSession(self: *@This()) ?Ui {
            if (self.in_session) return null;
            const ui = self.ui orelse return null;
            self.in_session = true;
            return ui;
        }

        pub fn endSession(self: *@This()) void {
            self.in_session = false;
        }

        pub fn deinit(self: *@This()) void {
            if (self.breakpoints) |*table| table.deinit();
        }
    };
}
