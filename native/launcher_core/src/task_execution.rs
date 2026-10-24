//! K3.0 synthetic ownership/lifecycle prototype; not a production runner.
//! No processes, authentication, filesystem, networking or FFI registration.

use std::collections::{HashMap, HashSet};

const REAL_EXECUTION_SUPPORTED: bool = false;

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub(crate) struct Binding {
    source_id: String,
    identity_binding: String,
    // An opaque canonical key supplied by fixtures. This prototype does not
    // resolve real paths, symlinks, auth principals or organization membership.
    workspace_key: String,
    task_id: String,
    source_epoch: u64,
    generation: u64,
}

impl Binding {
    pub(crate) fn fixture(
        source_id: &str,
        identity_binding: &str,
        workspace_key: &str,
        task_id: &str,
        source_epoch: u64,
        generation: u64,
    ) -> Result<Self, Error> {
        if !source_id.starts_with("profile-") || source_id.len() <= "profile-".len() {
            return Err(Error::InvalidBinding);
        }
        if [source_id, identity_binding, workspace_key, task_id]
            .iter()
            .any(|s| s.trim().is_empty() || s.trim() != *s)
            || source_epoch == 0
            || generation == 0
        {
            return Err(Error::InvalidBinding);
        }
        Ok(Self {
            source_id: source_id.into(),
            identity_binding: identity_binding.into(),
            workspace_key: workspace_key.into(),
            task_id: task_id.into(),
            source_epoch,
            generation,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub(crate) struct Route {
    binding: Binding,
    thread_id: String,
    turn_id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum State {
    Prepared,
    Running,
    AwaitingApproval,
    Cancelling,
    Recoverable,
    Completed,
    Cancelled,
    Failed,
}

impl State {
    fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Cancelled | Self::Failed)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    Completed,
    Cancelled,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    InvalidBinding,
    DuplicateTask,
    SourceBusy,
    WorkspaceBusy,
    OwnershipMismatch,
    InvalidState,
    InvalidApproval,
    ThreadOwned,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ApprovalDecision {
    route: Route,
    request_id: String,
    approved: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ResumePlan {
    route: Route,
    real_execution_supported: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RecoveryRecord {
    route: Route,
    cancel_requested: bool,
    seen_requests: HashSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Task {
    binding: Binding,
    route: Option<Route>,
    state: State,
    pending: HashSet<String>,
    seen_requests: HashSet<String>,
    runtime_released: bool,
    cancel_requested: bool,
}

/// Synthetic reservations only: not the production account_sources arbiter.
/// Retained task/thread tombstones reject replay in the lifetime of a fixture.
/// A real adapter still needs bounded durable history, trusted provenance,
/// actual canonical workspace validation, and shared credential leases.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Registry {
    tasks: HashMap<String, Task>,
    sources: HashMap<String, String>,
    workspaces: HashMap<String, String>,
    threads: HashMap<(String, String), String>,
}

impl Registry {
    pub(crate) fn prepare(&mut self, binding: Binding) -> Result<(), Error> {
        if self.tasks.contains_key(&binding.task_id) {
            return Err(Error::DuplicateTask);
        }
        if self.sources.contains_key(&binding.source_id) {
            return Err(Error::SourceBusy);
        }
        if self.workspaces.contains_key(&binding.workspace_key) {
            return Err(Error::WorkspaceBusy);
        }
        self.sources
            .insert(binding.source_id.clone(), binding.task_id.clone());
        self.workspaces
            .insert(binding.workspace_key.clone(), binding.task_id.clone());
        self.tasks.insert(
            binding.task_id.clone(),
            Task {
                binding,
                route: None,
                state: State::Prepared,
                pending: HashSet::new(),
                seen_requests: HashSet::new(),
                runtime_released: false,
                cancel_requested: false,
            },
        );
        Ok(())
    }

    fn task(&self, binding: &Binding) -> Result<&Task, Error> {
        self.tasks
            .get(&binding.task_id)
            .filter(|task| task.binding == *binding)
            .ok_or(Error::OwnershipMismatch)
    }

    fn owned(&self, route: &Route) -> Result<&Task, Error> {
        self.task(&route.binding)?
            .route
            .as_ref()
            .filter(|owned| *owned == route)
            .ok_or(Error::OwnershipMismatch)?;
        self.task(&route.binding)
    }

    pub(crate) fn state(&self, binding: &Binding) -> Result<State, Error> {
        Ok(self.task(binding)?.state)
    }

    fn route(&self, binding: &Binding) -> Result<&Route, Error> {
        self.task(binding)?
            .route
            .as_ref()
            .ok_or(Error::InvalidState)
    }

    pub(crate) fn abort_prepared(
        &mut self,
        binding: &Binding,
        outcome: Outcome,
    ) -> Result<(), Error> {
        if self.task(binding)?.state != State::Prepared || outcome == Outcome::Completed {
            return Err(Error::InvalidState);
        }
        self.tasks.get_mut(&binding.task_id).unwrap().state = match outcome {
            Outcome::Cancelled => State::Cancelled,
            _ => State::Failed,
        };
        Ok(())
    }

    pub(crate) fn started(
        &mut self,
        binding: &Binding,
        thread: &str,
        turn: &str,
    ) -> Result<Route, Error> {
        if self.task(binding)?.state != State::Prepared {
            return Err(Error::InvalidState);
        }
        if thread.trim().is_empty() || turn.trim().is_empty() {
            return Err(Error::InvalidBinding);
        }
        let thread_key = (binding.source_id.clone(), thread.into());
        if self.threads.contains_key(&thread_key) {
            return Err(Error::ThreadOwned);
        }
        let route = Route {
            binding: binding.clone(),
            thread_id: thread.into(),
            turn_id: turn.into(),
        };
        self.threads.insert(thread_key, binding.task_id.clone());
        let task = self.tasks.get_mut(&binding.task_id).unwrap();
        task.route = Some(route.clone());
        task.state = State::Running;
        Ok(route)
    }

    pub(crate) fn approval(&mut self, route: &Route, request: &str) -> Result<(), Error> {
        let task = self.owned(route)?;
        if !matches!(task.state, State::Running | State::AwaitingApproval)
            || request.trim().is_empty()
            || task.seen_requests.contains(request)
        {
            return Err(Error::InvalidApproval);
        }
        let task = self.tasks.get_mut(&route.binding.task_id).unwrap();
        task.seen_requests.insert(request.into());
        task.pending.insert(request.into());
        task.state = State::AwaitingApproval;
        Ok(())
    }

    pub(crate) fn decision(
        &mut self,
        route: &Route,
        request: &str,
        approved: bool,
    ) -> Result<ApprovalDecision, Error> {
        let task = self.owned(route)?;
        if task.state != State::AwaitingApproval || !task.pending.contains(request) {
            return Err(Error::InvalidApproval);
        }
        let task = self.tasks.get_mut(&route.binding.task_id).unwrap();
        task.pending.remove(request);
        if task.pending.is_empty() {
            task.state = State::Running;
        }
        Ok(ApprovalDecision {
            route: route.clone(),
            request_id: request.into(),
            approved,
        })
    }

    pub(crate) fn cancel(&mut self, route: &Route) -> Result<(), Error> {
        if !matches!(
            self.owned(route)?.state,
            State::Running | State::AwaitingApproval
        ) {
            return Err(Error::InvalidState);
        }
        let task = self.tasks.get_mut(&route.binding.task_id).unwrap();
        task.pending.clear();
        task.state = State::Cancelling;
        task.cancel_requested = true;
        Ok(())
    }

    pub(crate) fn terminal(&mut self, route: &Route, outcome: Outcome) -> Result<(), Error> {
        if !matches!(
            self.owned(route)?.state,
            State::Running | State::AwaitingApproval | State::Cancelling
        ) {
            return Err(Error::InvalidState);
        }
        let task = self.tasks.get_mut(&route.binding.task_id).unwrap();
        task.pending.clear();
        // Only an exact terminal event owns the outcome. A submitted interrupt
        // neither promises cancellation nor overwrites a completion that won.
        task.state = match outcome {
            Outcome::Completed => State::Completed,
            Outcome::Cancelled => State::Cancelled,
            Outcome::Failed => State::Failed,
        };
        Ok(())
    }

    pub(crate) fn disconnected(&mut self, route: &Route) -> Result<(), Error> {
        if !matches!(
            self.owned(route)?.state,
            State::Running | State::AwaitingApproval | State::Cancelling
        ) {
            return Err(Error::InvalidState);
        }
        let task = self.tasks.get_mut(&route.binding.task_id).unwrap();
        task.pending.clear();
        task.state = State::Recoverable;
        Ok(())
    }

    fn recovery_record(&self, route: &Route) -> Result<RecoveryRecord, Error> {
        let task = self.owned(route)?;
        if task.state != State::Recoverable {
            return Err(Error::InvalidState);
        }
        Ok(RecoveryRecord {
            route: route.clone(),
            cancel_requested: task.cancel_requested,
            seen_requests: task.seen_requests.clone(),
        })
    }

    /// Input provenance is trusted fixture metadata, not arbitrary disk data.
    fn restore_owned_fixture(&mut self, record: RecoveryRecord) -> Result<(), Error> {
        let route = record.route;
        let thread_key = (route.binding.source_id.clone(), route.thread_id.clone());
        if route.thread_id.trim().is_empty() || route.turn_id.trim().is_empty() {
            return Err(Error::InvalidBinding);
        }
        if self.threads.contains_key(&thread_key) {
            return Err(Error::ThreadOwned);
        }
        self.prepare(route.binding.clone())?;
        self.threads
            .insert(thread_key, route.binding.task_id.clone());
        let task = self.tasks.get_mut(&route.binding.task_id).unwrap();
        task.state = State::Recoverable;
        task.cancel_requested = record.cancel_requested;
        task.seen_requests = record.seen_requests;
        task.route = Some(route);
        Ok(())
    }

    fn resume_plan(&self, route: &Route) -> Result<ResumePlan, Error> {
        let task = self.owned(route)?;
        if task.state != State::Recoverable || task.cancel_requested {
            return Err(Error::InvalidState);
        }
        Ok(ResumePlan {
            route: route.clone(),
            real_execution_supported: REAL_EXECUTION_SUPPORTED,
        })
    }

    pub(crate) fn release_after_cleanup(&mut self, binding: &Binding) -> Result<(), Error> {
        let task = self.task(binding)?;
        if !task.state.is_terminal() || task.runtime_released {
            return Err(Error::InvalidState);
        }
        self.tasks
            .get_mut(&binding.task_id)
            .unwrap()
            .runtime_released = true;
        self.sources.remove(&binding.source_id);
        self.workspaces.remove(&binding.workspace_key);
        Ok(())
    }
}

#[cfg(test)]
mod tests;
