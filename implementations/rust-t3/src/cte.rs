// Common table expressions in scope while a statement is planned.
//
// WITH clauses are lexically scoped; planning is recursive, so the clauses
// visible at any point form a stack. A CTE body is planned where it is
// referenced, with the stack cut back to the frame that defines it.

use std::cell::{OnceCell, RefCell};
use std::rc::Rc;

use crate::ast::{Cte, With};
use crate::eval::SrcCol;
use crate::query::Rows;

pub enum State {
    Idle,
    /// The body is being planned: a reference now is circular.
    Expanding,
    /// A recursive select is being planned: references read the queue row.
    Recursive { slot: Rc<RefCell<Rows>>, cols: Vec<SrcCol> },
}

pub struct Entry {
    pub cte: Cte,
    pub state: RefCell<State>,
    /// Rows of an uncorrelated CTE, computed once per statement.
    pub cache: Rc<OnceCell<Rows>>,
}

pub struct Frame {
    pub entries: Vec<Entry>,
}

thread_local! {
    static STACK: RefCell<Vec<Rc<Frame>>> = const { RefCell::new(Vec::new()) };
}

/// Restores the previous stack when dropped (also on unwinding).
struct Restore(Option<Vec<Rc<Frame>>>);

impl Drop for Restore {
    fn drop(&mut self) {
        if let Some(s) = self.0.take() {
            STACK.with(|st| *st.borrow_mut() = s);
        }
    }
}

fn run_with_stack<T>(stack: Vec<Rc<Frame>>, f: impl FnOnce() -> T) -> T {
    let old = STACK.with(|st| std::mem::replace(&mut *st.borrow_mut(), stack));
    let _guard = Restore(Some(old));
    f()
}

/// Runs `f` with the CTEs of `with` in scope.
pub fn with_scope<T>(with: Option<&Rc<With>>, f: impl FnOnce() -> T) -> T {
    let Some(w) = with else { return f() };
    let frame = Rc::new(Frame {
        entries: w
            .ctes
            .iter()
            .map(|c| Entry { cte: c.clone(), state: RefCell::new(State::Idle), cache: Rc::new(OnceCell::new()) })
            .collect(),
    });
    let mut stack = STACK.with(|st| st.borrow().clone());
    stack.push(frame);
    run_with_stack(stack, f)
}

/// Runs `f` with no CTEs in scope (view bodies).
pub fn without_ctes<T>(f: impl FnOnce() -> T) -> T {
    run_with_stack(Vec::new(), f)
}

/// Runs `f` with only the frames up to and including `depth` in scope.
pub fn upto<T>(depth: usize, f: impl FnOnce() -> T) -> T {
    let mut stack = STACK.with(|st| st.borrow().clone());
    stack.truncate(depth + 1);
    run_with_stack(stack, f)
}

/// The innermost CTE named `name`: its frame, the frame's depth and the
/// entry index.
pub fn lookup(name: &str) -> Option<(Rc<Frame>, usize, usize)> {
    STACK.with(|st| {
        let st = st.borrow();
        for (d, f) in st.iter().enumerate().rev() {
            if let Some(i) = f.entries.iter().position(|e| e.cte.name.eq_ignore_ascii_case(name)) {
                return Some((f.clone(), d, i));
            }
        }
        None
    })
}

pub fn is_cte(name: &str) -> bool {
    lookup(name).is_some()
}
