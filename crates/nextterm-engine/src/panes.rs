//! Pane splitter — recursive binary tree primitive for split panes.
//!
//! See `spec/team-split-pane.md` §1 for the architecture. The Rust core owns
//! the logical tree; Swift mirrors layout via flat `Vec<(PaneId, LayoutRect)>`
//! frames computed from window dimensions.
//!
//! M4-1 scope: tree primitive only — no FFI, no PTY allocation.

use std::num::NonZeroU64;

/// Stable identifier for a pane (leaf in the tree).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PaneId(pub u64);

impl PaneId {
    #[must_use]
    pub const fn new(id: u64) -> Self {
        Self(id)
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// Identifier for an internal split node, used by `resize_split`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SplitId(NonZeroU64);

impl SplitId {
    /// Reconstruct a `SplitId` from its raw `u64` representation.
    /// Returns `None` for `0` (the FFI failure sentinel — see
    /// `nextterm_ffi::PANE_TREE_SPLIT_FAILED`). Required by the M4-2
    /// FFI surface so Swift can hand a previously-returned `SplitId`
    /// back to `resize_split`.
    #[must_use]
    pub fn from_raw(raw: u64) -> Option<Self> {
        NonZeroU64::new(raw).map(Self)
    }

    #[must_use]
    pub fn get(self) -> u64 {
        self.0.get()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SplitDirection {
    Horizontal,
    Vertical,
}

/// Recursive node in the pane tree.
#[derive(Debug, Clone)]
pub enum PaneNode {
    Leaf(PaneId),
    Split {
        id: SplitId,
        direction: SplitDirection,
        ratio: f32,
        left: Box<PaneNode>,
        right: Box<PaneNode>,
    },
}

/// Owns the recursive pane layout for a single window.
#[derive(Debug, Clone)]
pub struct PaneTree {
    root: PaneNode,
    next_split_id: u64,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SplitError {
    #[error("pane {0:?} not found")]
    PaneNotFound(PaneId),
    #[error("split {0:?} not found")]
    SplitNotFound(SplitId),
    #[error("depth cap {cap} exceeded for pane {target:?}")]
    DepthCapExceeded { target: PaneId, cap: usize },
    #[error("attempted to split with duplicate pane id {0:?}")]
    DuplicatePane(PaneId),
    #[error("cannot remove last pane in tree")]
    LastPane,
}

/// MVP depth cap per `spec/team-split-pane.md` §1.
pub const DEPTH_CAP: usize = 2;

const RATIO_MIN: f32 = 0.1;
const RATIO_MAX: f32 = 0.9;

/// Axis-aligned rectangle (logical units, top-left origin).
///
/// Mirrors `CGRect` shape but lives in Rust for tree-side layout flattening.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LayoutRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl LayoutRect {
    #[must_use]
    pub const fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }
}

impl PaneTree {
    /// Build a fresh tree with a single pane.
    #[must_use]
    pub fn new(initial: PaneId) -> Self {
        Self {
            root: PaneNode::Leaf(initial),
            next_split_id: 1,
        }
    }

    #[must_use]
    pub fn root(&self) -> &PaneNode {
        &self.root
    }

    /// Iterate every pane id in the tree (in-order).
    #[must_use]
    pub fn pane_ids(&self) -> Vec<PaneId> {
        let mut acc = Vec::new();
        collect_pane_ids(&self.root, &mut acc);
        acc
    }

    /// Returns true if the pane id exists somewhere in the tree.
    #[must_use]
    pub fn contains(&self, pane: PaneId) -> bool {
        self.pane_ids().contains(&pane)
    }

    /// Replace the leaf for `target` with a Split where target is the left
    /// child and `new_pane` is the right child.
    pub fn split_pane(
        &mut self,
        target: PaneId,
        direction: SplitDirection,
        new_pane: PaneId,
    ) -> Result<SplitId, SplitError> {
        if target == new_pane {
            return Err(SplitError::DuplicatePane(new_pane));
        }
        if self.contains(new_pane) {
            return Err(SplitError::DuplicatePane(new_pane));
        }
        if !self.contains(target) {
            return Err(SplitError::PaneNotFound(target));
        }
        let depth = depth_to_pane(&self.root, target).expect("pane existence checked above");
        // Splitting a leaf at depth d produces a Split at depth d. The deepest
        // node after the operation is at depth d+1. We cap "split depth" at
        // DEPTH_CAP, so reject when d+1 > DEPTH_CAP.
        if depth + 1 > DEPTH_CAP {
            return Err(SplitError::DepthCapExceeded {
                target,
                cap: DEPTH_CAP,
            });
        }
        let raw = self.next_split_id;
        self.next_split_id += 1;
        let split_id = SplitId::from_raw(raw).expect("next_split_id starts at 1 and only grows");
        let inserted = insert_split(&mut self.root, target, direction, new_pane, split_id);
        debug_assert!(inserted, "target was found by contains() above");
        Ok(split_id)
    }

    /// Remove a leaf. If its parent split now has only the sibling left, the
    /// sibling subtree replaces the parent entirely.
    pub fn remove_pane(&mut self, pane: PaneId) -> Result<(), SplitError> {
        if !self.contains(pane) {
            return Err(SplitError::PaneNotFound(pane));
        }
        match &self.root {
            PaneNode::Leaf(id) if *id == pane => return Err(SplitError::LastPane),
            _ => {}
        }
        let removed = remove_pane_inner(&mut self.root, pane);
        debug_assert!(removed, "containment was verified above");
        Ok(())
    }

    /// Update a split's divider ratio. Clamped to `[0.1, 0.9]`.
    pub fn resize_split(&mut self, split: SplitId, new_ratio: f32) -> Result<(), SplitError> {
        let node = find_split_mut(&mut self.root, split).ok_or(SplitError::SplitNotFound(split))?;
        if let PaneNode::Split { ratio, .. } = node {
            *ratio = new_ratio.clamp(RATIO_MIN, RATIO_MAX);
            Ok(())
        } else {
            unreachable!("find_split_mut only returns Split nodes")
        }
    }

    /// Compute layout frames: a flat list of `(PaneId, LayoutRect)` for the
    /// entire window, given outer dimensions.
    #[must_use]
    pub fn layout_frames(&self, window: LayoutRect) -> Vec<(PaneId, LayoutRect)> {
        let mut acc = Vec::new();
        flatten(&self.root, window, &mut acc);
        acc
    }
}

fn collect_pane_ids(node: &PaneNode, acc: &mut Vec<PaneId>) {
    match node {
        PaneNode::Leaf(id) => acc.push(*id),
        PaneNode::Split { left, right, .. } => {
            collect_pane_ids(left, acc);
            collect_pane_ids(right, acc);
        }
    }
}

/// Depth of a leaf, where the root leaf is depth 0 and root-Split's children
/// are depth 1.
fn depth_to_pane(node: &PaneNode, target: PaneId) -> Option<usize> {
    match node {
        PaneNode::Leaf(id) if *id == target => Some(0),
        PaneNode::Leaf(_) => None,
        PaneNode::Split { left, right, .. } => depth_to_pane(left, target)
            .or_else(|| depth_to_pane(right, target))
            .map(|d| d + 1),
    }
}

fn insert_split(
    node: &mut PaneNode,
    target: PaneId,
    direction: SplitDirection,
    new_pane: PaneId,
    split_id: SplitId,
) -> bool {
    match node {
        PaneNode::Leaf(id) if *id == target => {
            let left = Box::new(PaneNode::Leaf(*id));
            let right = Box::new(PaneNode::Leaf(new_pane));
            *node = PaneNode::Split {
                id: split_id,
                direction,
                ratio: 0.5,
                left,
                right,
            };
            true
        }
        PaneNode::Leaf(_) => false,
        PaneNode::Split { left, right, .. } => {
            insert_split(left, target, direction, new_pane, split_id)
                || insert_split(right, target, direction, new_pane, split_id)
        }
    }
}

fn remove_pane_inner(node: &mut PaneNode, pane: PaneId) -> bool {
    let PaneNode::Split { left, right, .. } = node else {
        return false;
    };

    if let PaneNode::Leaf(id) = **left {
        if id == pane {
            let sibling = std::mem::replace(right.as_mut(), PaneNode::Leaf(PaneId(0)));
            *node = sibling;
            return true;
        }
    }
    if let PaneNode::Leaf(id) = **right {
        if id == pane {
            let sibling = std::mem::replace(left.as_mut(), PaneNode::Leaf(PaneId(0)));
            *node = sibling;
            return true;
        }
    }
    remove_pane_inner(left, pane) || remove_pane_inner(right, pane)
}

fn find_split_mut(node: &mut PaneNode, target: SplitId) -> Option<&mut PaneNode> {
    match node {
        PaneNode::Leaf(_) => None,
        PaneNode::Split { id, .. } if *id == target => Some(node),
        PaneNode::Split { left, right, .. } => {
            if let Some(found) = find_split_mut(left, target) {
                Some(found)
            } else {
                find_split_mut(right, target)
            }
        }
    }
}

fn flatten(node: &PaneNode, rect: LayoutRect, acc: &mut Vec<(PaneId, LayoutRect)>) {
    match node {
        PaneNode::Leaf(id) => acc.push((*id, rect)),
        PaneNode::Split {
            direction,
            ratio,
            left,
            right,
            ..
        } => {
            let r = ratio.clamp(RATIO_MIN, RATIO_MAX);
            let (left_bounds, right_bounds) = match direction {
                SplitDirection::Horizontal => {
                    // Horizontal split = stacked vertically (top/bottom).
                    let top_h = rect.height * r;
                    (
                        LayoutRect::new(rect.x, rect.y, rect.width, top_h),
                        LayoutRect::new(rect.x, rect.y + top_h, rect.width, rect.height - top_h),
                    )
                }
                SplitDirection::Vertical => {
                    // Vertical split = side-by-side (left/right).
                    let left_w = rect.width * r;
                    (
                        LayoutRect::new(rect.x, rect.y, left_w, rect.height),
                        LayoutRect::new(rect.x + left_w, rect.y, rect.width - left_w, rect.height),
                    )
                }
            };
            flatten(left, left_bounds, acc);
            flatten(right, right_bounds, acc);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx_eq(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-4
    }

    fn rect_eq(a: LayoutRect, b: LayoutRect) -> bool {
        approx_eq(a.x, b.x)
            && approx_eq(a.y, b.y)
            && approx_eq(a.width, b.width)
            && approx_eq(a.height, b.height)
    }

    #[test]
    fn single_leaf_layout_fills_window() {
        let tree = PaneTree::new(PaneId(1));
        let frames = tree.layout_frames(LayoutRect::new(0.0, 0.0, 800.0, 600.0));
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].0, PaneId(1));
        assert!(rect_eq(
            frames[0].1,
            LayoutRect::new(0.0, 0.0, 800.0, 600.0)
        ));
    }

    #[test]
    fn vertical_split_yields_two_side_by_side_frames() {
        let mut tree = PaneTree::new(PaneId(1));
        tree.split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();
        let frames = tree.layout_frames(LayoutRect::new(0.0, 0.0, 800.0, 600.0));
        assert_eq!(frames.len(), 2);
        assert!(rect_eq(
            frames[0].1,
            LayoutRect::new(0.0, 0.0, 400.0, 600.0)
        ));
        assert!(rect_eq(
            frames[1].1,
            LayoutRect::new(400.0, 0.0, 400.0, 600.0)
        ));
    }

    #[test]
    fn horizontal_split_stacks_top_and_bottom() {
        let mut tree = PaneTree::new(PaneId(1));
        tree.split_pane(PaneId(1), SplitDirection::Horizontal, PaneId(2))
            .unwrap();
        let frames = tree.layout_frames(LayoutRect::new(0.0, 0.0, 800.0, 600.0));
        assert_eq!(frames.len(), 2);
        assert!(rect_eq(
            frames[0].1,
            LayoutRect::new(0.0, 0.0, 800.0, 300.0)
        ));
        assert!(rect_eq(
            frames[1].1,
            LayoutRect::new(0.0, 300.0, 800.0, 300.0)
        ));
    }

    #[test]
    fn nested_split_at_depth_cap_succeeds() {
        let mut tree = PaneTree::new(PaneId(1));
        tree.split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();
        tree.split_pane(PaneId(2), SplitDirection::Horizontal, PaneId(3))
            .unwrap();
        let ids = tree.pane_ids();
        assert_eq!(ids, vec![PaneId(1), PaneId(2), PaneId(3)]);
    }

    #[test]
    fn split_beyond_depth_cap_rejected() {
        let mut tree = PaneTree::new(PaneId(1));
        tree.split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();
        tree.split_pane(PaneId(2), SplitDirection::Horizontal, PaneId(3))
            .unwrap();
        // PaneId(3) is at depth 2 — splitting it would create a node at depth 3.
        let err = tree
            .split_pane(PaneId(3), SplitDirection::Vertical, PaneId(4))
            .unwrap_err();
        assert_eq!(
            err,
            SplitError::DepthCapExceeded {
                target: PaneId(3),
                cap: DEPTH_CAP
            }
        );
    }

    #[test]
    fn split_with_unknown_target_errors() {
        let mut tree = PaneTree::new(PaneId(1));
        let err = tree
            .split_pane(PaneId(99), SplitDirection::Vertical, PaneId(2))
            .unwrap_err();
        assert_eq!(err, SplitError::PaneNotFound(PaneId(99)));
    }

    #[test]
    fn split_with_duplicate_pane_id_errors() {
        let mut tree = PaneTree::new(PaneId(1));
        tree.split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();
        let err = tree
            .split_pane(PaneId(2), SplitDirection::Vertical, PaneId(1))
            .unwrap_err();
        assert_eq!(err, SplitError::DuplicatePane(PaneId(1)));
    }

    #[test]
    fn remove_pane_collapses_parent_split() {
        let mut tree = PaneTree::new(PaneId(1));
        tree.split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();
        tree.remove_pane(PaneId(2)).unwrap();
        assert_eq!(tree.pane_ids(), vec![PaneId(1)]);
        assert!(matches!(tree.root(), PaneNode::Leaf(PaneId(1))));
    }

    #[test]
    fn remove_pane_in_nested_subtree_collapses_locally() {
        let mut tree = PaneTree::new(PaneId(1));
        tree.split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();
        tree.split_pane(PaneId(2), SplitDirection::Horizontal, PaneId(3))
            .unwrap();
        tree.remove_pane(PaneId(3)).unwrap();
        // Inner split collapses; tree returns to a single Vertical split of 1|2.
        assert_eq!(tree.pane_ids(), vec![PaneId(1), PaneId(2)]);
        match tree.root() {
            PaneNode::Split {
                direction,
                left,
                right,
                ..
            } => {
                assert_eq!(*direction, SplitDirection::Vertical);
                assert!(matches!(**left, PaneNode::Leaf(PaneId(1))));
                assert!(matches!(**right, PaneNode::Leaf(PaneId(2))));
            }
            PaneNode::Leaf(_) => panic!("expected Split"),
        }
    }

    #[test]
    fn remove_last_pane_errors() {
        let mut tree = PaneTree::new(PaneId(1));
        let err = tree.remove_pane(PaneId(1)).unwrap_err();
        assert_eq!(err, SplitError::LastPane);
    }

    #[test]
    fn remove_unknown_pane_errors() {
        let mut tree = PaneTree::new(PaneId(1));
        let err = tree.remove_pane(PaneId(42)).unwrap_err();
        assert_eq!(err, SplitError::PaneNotFound(PaneId(42)));
    }

    #[test]
    fn resize_split_clamps_to_bounds() {
        let mut tree = PaneTree::new(PaneId(1));
        let split = tree
            .split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();

        tree.resize_split(split, 0.05).unwrap();
        let frames = tree.layout_frames(LayoutRect::new(0.0, 0.0, 1000.0, 500.0));
        assert!(approx_eq(frames[0].1.width, 100.0));

        tree.resize_split(split, 0.99).unwrap();
        let frames = tree.layout_frames(LayoutRect::new(0.0, 0.0, 1000.0, 500.0));
        assert!(approx_eq(frames[0].1.width, 900.0));

        tree.resize_split(split, 0.25).unwrap();
        let frames = tree.layout_frames(LayoutRect::new(0.0, 0.0, 1000.0, 500.0));
        assert!(approx_eq(frames[0].1.width, 250.0));
    }

    #[test]
    fn resize_unknown_split_errors() {
        let mut tree = PaneTree::new(PaneId(1));
        let bogus = SplitId::from_raw(42).unwrap();
        let err = tree.resize_split(bogus, 0.5).unwrap_err();
        assert_eq!(err, SplitError::SplitNotFound(bogus));
    }

    #[test]
    fn nested_layout_flatten_preserves_in_order_traversal() {
        let mut tree = PaneTree::new(PaneId(1));
        tree.split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();
        tree.split_pane(PaneId(2), SplitDirection::Horizontal, PaneId(3))
            .unwrap();
        let frames = tree.layout_frames(LayoutRect::new(0.0, 0.0, 1000.0, 800.0));
        assert_eq!(frames.len(), 3);
        assert_eq!(frames[0].0, PaneId(1));
        assert_eq!(frames[1].0, PaneId(2));
        assert_eq!(frames[2].0, PaneId(3));
        // Pane 1 is left half.
        assert!(rect_eq(
            frames[0].1,
            LayoutRect::new(0.0, 0.0, 500.0, 800.0)
        ));
        // Panes 2/3 split right half horizontally.
        assert!(rect_eq(
            frames[1].1,
            LayoutRect::new(500.0, 0.0, 500.0, 400.0)
        ));
        assert!(rect_eq(
            frames[2].1,
            LayoutRect::new(500.0, 400.0, 500.0, 400.0)
        ));
    }

    #[test]
    fn split_ids_are_unique_and_addressable() {
        let mut tree = PaneTree::new(PaneId(1));
        let s1 = tree
            .split_pane(PaneId(1), SplitDirection::Vertical, PaneId(2))
            .unwrap();
        let s2 = tree
            .split_pane(PaneId(2), SplitDirection::Horizontal, PaneId(3))
            .unwrap();
        assert_ne!(s1, s2);
        tree.resize_split(s1, 0.7).unwrap();
        tree.resize_split(s2, 0.3).unwrap();
    }
}
