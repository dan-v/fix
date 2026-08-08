//! Sibling-sweep diagnostics (`FIX_SIBLING_LOG=1`): run start, per-member
//! thunk-creation spikes, and per-sweep heap growth. Pure reporting — the
//! sweep task in `worker.zig` constructs one (or not) and calls the hooks;
//! the force loop itself is identical with logging on or off.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const observ = @import("base").observ;
const worker_id_mod = @import("base").worker_id;
const VM = @import("../../vm/context.zig").VM;
const vm_force = @import("../../vm/force.zig");

/// A member that created more thunks than this while being forced gets its
/// own log line (a speculation flood suspect); quieter members stay silent.
const spike_min_thunks = 2000;

pub const SweepDiag = struct {
    vm: *VM,
    attrs_id: types.ObjectId,
    objects_before: u32,
    label_buf: [160]u8 = undefined,
    rendered_buf: [224]u8 = undefined,

    /// Captured before a member is forced: the label must be read while the
    /// thunk is still unresolved, and the creation counter before the force.
    pub const Member = struct {
        created_before: u64,
        subject: observ.Subject,
    };

    /// Log the sweep header (submit->run latency pairs with the
    /// `sweep-submit` line in `vm/access.zig`).
    pub fn begin(vm: *VM, attrs_id: types.ObjectId, entries: heap_mod.AttrsView) SweepDiag {
        var self = SweepDiag{
            .vm = vm,
            .attrs_id = attrs_id,
            .objects_before = vm.heap.counts().objects,
        };
        var label: []const u8 = "?";
        for (entries.values) |entry_value| {
            if (!entry_value.isThunk()) continue;
            const subject = vm_force.thunkLabel(vm, entry_value.asObjectId(), &self.label_buf);
            if (subject.isEmpty()) continue;
            label = self.render(subject);
            break;
        }
        std.debug.print("sweep attrs={d} n={d} t_us={d} worker={d} claimer={d} first_attr={s} member={s}\n", .{
            attrs_id,                              entries.len(),
            vm_force.diagNowUs(),                  worker_id_mod.currentId(),
            vm.executionContextConst().claimer_id, vm.intern.get(entries.names[0]),
            label,
        });
        return self;
    }

    pub fn memberBegin(self: *SweepDiag, entry_value: Value) Member {
        return .{
            .created_before = self.vm.heap.currentLocal().thunks_created,
            .subject = vm_force.thunkLabel(self.vm, entry_value.asObjectId(), &self.label_buf),
        };
    }

    pub fn memberEnd(self: *SweepDiag, entry_name: types.InternId, member: Member) void {
        const created = self.vm.heap.currentLocal().thunks_created -| member.created_before;
        if (created <= spike_min_thunks) return;
        std.debug.print("sweep-member attrs={d} attr={s} member={s} created={d} t_us={d} claimer={d}\n", .{
            self.attrs_id,               self.vm.intern.get(entry_name),
            self.render(member.subject), created,
            vm_force.diagNowUs(),        self.vm.executionContextConst().claimer_id,
        });
    }

    pub fn end(self: *SweepDiag) void {
        std.debug.print("sweep attrs={d} done: t_us={d} heap_growth={d}\n", .{
            self.attrs_id, vm_force.diagNowUs(), self.vm.heap.counts().objects -| self.objects_before,
        });
    }

    fn render(self: *SweepDiag, subject: observ.Subject) []const u8 {
        return switch (subject) {
            .source => |source| std.fmt.bufPrint(&self.rendered_buf, "{s}:{d}", .{
                std.fs.path.basename(self.vm.intern.get(source.file)), source.line,
            }) catch "?",
            .text, .path, .url => |text| if (text.len == 0) "?" else text,
            .none => "?",
        };
    }
};
