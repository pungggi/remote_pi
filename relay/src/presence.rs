use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tokio::sync::Mutex;

#[derive(Debug, Default)]
struct Inner {
    /// subscribers_of[X] = set of peer_ids that want push when X connects/disconnects.
    subscribers_of: HashMap<String, HashSet<String>>,
    /// subscriptions_by[Y] = set of peer_ids that Y is watching (for efficient cleanup).
    subscriptions_by: HashMap<String, HashSet<String>>,
    /// Epoch-ms timestamp of the most recent disconnect for each peer.
    last_offline_ts: HashMap<String, i64>,
}

#[derive(Clone, Debug, Default)]
pub struct PresenceManager {
    inner: Arc<Mutex<Inner>>,
}

#[derive(serde::Serialize)]
pub struct PeerPresence {
    pub peer: String,
    pub online: bool,
    pub since_ts: Option<i64>,
}

impl PresenceManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// Replaces `subscriber`'s full subscription list with `peers`.
    /// Passing an empty list is equivalent to unsubscribing from everything.
    pub async fn subscribe(&self, subscriber: String, peers: Vec<String>) {
        let mut g = self.inner.lock().await;
        // Remove subscriber from all currently-watched sets.
        if let Some(old) = g.subscriptions_by.remove(&subscriber) {
            for peer in &old {
                if let Some(set) = g.subscribers_of.get_mut(peer) {
                    set.remove(&subscriber);
                }
            }
        }
        // Add to new sets.
        let new_set: HashSet<String> = peers.into_iter().collect();
        for peer in &new_set {
            g.subscribers_of
                .entry(peer.clone())
                .or_default()
                .insert(subscriber.clone());
        }
        if !new_set.is_empty() {
            g.subscriptions_by.insert(subscriber, new_set);
        }
    }

    /// Removes `peers` from `subscriber`'s watched list.
    pub async fn unsubscribe(&self, subscriber: &str, peers: Vec<String>) {
        let mut g = self.inner.lock().await;
        for peer in &peers {
            if let Some(set) = g.subscribers_of.get_mut(peer) {
                set.remove(subscriber);
            }
            if let Some(subs) = g.subscriptions_by.get_mut(subscriber) {
                subs.remove(peer);
            }
        }
    }

    /// Removes all subscriptions for `subscriber` (called on disconnect to prevent leaks).
    pub async fn unsubscribe_all(&self, subscriber: &str) {
        let mut g = self.inner.lock().await;
        if let Some(peers) = g.subscriptions_by.remove(subscriber) {
            for peer in &peers {
                if let Some(set) = g.subscribers_of.get_mut(peer) {
                    set.remove(subscriber);
                }
            }
        }
    }

    /// Returns everyone who subscribed to `peer`.
    pub async fn subscribers_of(&self, peer: &str) -> Vec<String> {
        let g = self.inner.lock().await;
        g.subscribers_of
            .get(peer)
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// Snapshot of every (target, subscriber) pair — the re-validation sweep
    /// (PR #24 follow-up #6) walks these and prunes pairs whose mesh
    /// membership disappeared after the subscription was authorized.
    pub async fn subscription_pairs(&self) -> Vec<(String, String)> {
        let g = self.inner.lock().await;
        let mut out = Vec::new();
        for (target, subscribers) in &g.subscribers_of {
            for subscriber in subscribers {
                out.push((target.clone(), subscriber.clone()));
            }
        }
        out
    }

    /// Builds a presence snapshot for `peers`. `is_online` is called while holding
    /// the presence lock, keeping the snapshot consistent.
    pub async fn snapshot(
        &self,
        peers: &[String],
        is_online: impl Fn(&str) -> bool,
    ) -> Vec<PeerPresence> {
        let g = self.inner.lock().await;
        peers
            .iter()
            .map(|peer| {
                let online = is_online(peer);
                let since_ts = if online {
                    None
                } else {
                    g.last_offline_ts.get(peer.as_str()).copied()
                };
                PeerPresence {
                    peer: peer.clone(),
                    online,
                    since_ts,
                }
            })
            .collect()
    }

    /// Records when `peer` went offline (stored for `since_ts` in future snapshots).
    pub async fn record_offline(&self, peer: &str, ts: i64) {
        self.inner
            .lock()
            .await
            .last_offline_ts
            .insert(peer.to_string(), ts);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn subscribe_replaces_list() {
        let pm = PresenceManager::new();
        pm.subscribe("B".into(), vec!["A".into(), "C".into()]).await;
        assert!(pm.subscribers_of("A").await.contains(&"B".to_string()));
        assert!(pm.subscribers_of("C").await.contains(&"B".to_string()));

        // Replace: B now only watches A
        pm.subscribe("B".into(), vec!["A".into()]).await;
        assert!(pm.subscribers_of("A").await.contains(&"B".to_string()));
        assert!(!pm.subscribers_of("C").await.contains(&"B".to_string()));
    }

    #[tokio::test]
    async fn subscribe_empty_equals_unsubscribe_all() {
        let pm = PresenceManager::new();
        pm.subscribe("B".into(), vec!["A".into()]).await;
        pm.subscribe("B".into(), vec![]).await; // empty → clear all
        assert!(pm.subscribers_of("A").await.is_empty());
    }

    #[tokio::test]
    async fn unsubscribe_all_cleans_subscriber_from_sets() {
        let pm = PresenceManager::new();
        pm.subscribe("B".into(), vec!["A".into(), "C".into()]).await;
        pm.unsubscribe_all("B").await;
        assert!(pm.subscribers_of("A").await.is_empty());
        assert!(pm.subscribers_of("C").await.is_empty());
    }

    #[tokio::test]
    async fn snapshot_reflects_online_flag() {
        let pm = PresenceManager::new();
        pm.record_offline("X", 1_000_000).await;
        let states = pm.snapshot(&["X".into(), "Y".into()], |p| p == "Y").await;
        assert_eq!(states.len(), 2);
        let x = states.iter().find(|s| s.peer == "X").unwrap();
        let y = states.iter().find(|s| s.peer == "Y").unwrap();
        assert!(!x.online);
        assert_eq!(x.since_ts, Some(1_000_000));
        assert!(y.online);
        assert!(y.since_ts.is_none());
    }
}
