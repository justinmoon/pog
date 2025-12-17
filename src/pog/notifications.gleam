//// PostgreSQL LISTEN/NOTIFY support.
////
//// This module provides a way to subscribe to PostgreSQL notification channels
//// and receive notifications when `NOTIFY` commands are executed.
////
//// ## Example
////
//// ```gleam
//// import gleam/erlang/process
//// import gleam/otp/actor
//// import pog
//// import pog/notifications
////
//// pub fn main() {
////   // Start a notification listener
////   let assert Ok(listener) =
////     notifications.default_config()
////     |> notifications.database("mydb")
////     |> notifications.user("postgres")
////     |> notifications.start()
////
////   // Subscribe to a channel
////   let assert Ok(subscription) = notifications.listen(listener, "events")
////
////   // Set up a selector to receive notifications
////   let selector =
////     process.new_selector()
////     |> notifications.selecting(subscription, fn(notif) { notif })
////
////   // Wait for a notification
////   let notification = process.select_forever(selector)
////   // notification.channel == "events"
////   // notification.payload contains the NOTIFY payload
//// }
//// ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Selector}
import gleam/erlang/reference.{type Reference}
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result

/// A listener process that maintains a dedicated connection to PostgreSQL
/// for receiving notifications.
///
/// Unlike a connection pool, a listener uses a single persistent connection
/// that stays open to receive asynchronous notifications from the database.
pub opaque type Listener {
  Listener(pid: Pid)
}

/// A reference to an active notification subscription.
///
/// This is returned by the `listen` function and can be used to:
/// - Set up a selector to receive notifications
/// - Unsubscribe from the channel using `unlisten`
///
/// The subscription is automatically cleaned up if the subscribing process
/// terminates.
pub opaque type Subscription {
  Subscription(listener: Pid, ref: Reference)
}

/// A notification received from PostgreSQL.
///
/// When a `NOTIFY channel, 'payload'` command is executed in PostgreSQL,
/// all listeners subscribed to that channel will receive a notification
/// containing the channel name and payload.
pub type Notification {
  Notification(
    /// The channel name that was notified.
    channel: String,
    /// The payload string sent with the notification.
    /// This will be an empty string if no payload was provided.
    payload: String,
  )
}

/// The result of calling `listen`.
///
/// When the listener is connected to the database, `Listening` is returned
/// and notifications will be received immediately.
///
/// When the listener is temporarily disconnected (e.g., during reconnection),
/// `ListeningEventually` is returned. The subscription is queued and will
/// become active once the connection is re-established. Notifications sent
/// while disconnected will not be received.
pub type ListenResult {
  /// Successfully subscribed and ready to receive notifications.
  Listening(Subscription)
  /// Subscription queued; will activate when connection is restored.
  ListeningEventually(Subscription)
}

/// Configuration for a notification listener.
pub type ListenerConfig {
  ListenerConfig(
    /// (default: 127.0.0.1): Database server hostname.
    host: String,
    /// (default: 5432): Port the server is listening on.
    port: Int,
    /// Name of database to use.
    database: String,
    /// Username to connect to database as.
    user: String,
    /// Password for the user.
    password: Option(String),
    /// (default: SslDisabled): Whether to use SSL or not.
    ssl: Ssl,
    /// (default: []): Connection parameters passed to PostgreSQL.
    connection_parameters: List(#(String, String)),
    /// (default: Ipv4) Which internet protocol to use for this connection.
    ip_version: IpVersion,
  )
}

/// SSL configuration options.
pub type Ssl {
  /// Verify the server certificate against trusted CAs.
  SslVerified
  /// Use SSL but don't verify the certificate.
  SslUnverified
  /// Don't use SSL.
  SslDisabled
}

/// IP version for the connection.
pub type IpVersion {
  Ipv4
  Ipv6
}

/// Create the default configuration for a notification listener.
///
/// You will need to set at least the `database` and `user` options.
pub fn default_config() -> ListenerConfig {
  ListenerConfig(
    host: "127.0.0.1",
    port: 5432,
    database: "postgres",
    user: "postgres",
    password: None,
    ssl: SslDisabled,
    connection_parameters: [],
    ip_version: Ipv4,
  )
}

/// Set the database server hostname.
pub fn host(config: ListenerConfig, host: String) -> ListenerConfig {
  ListenerConfig(..config, host:)
}

/// Set the port the server is listening on.
pub fn port(config: ListenerConfig, port: Int) -> ListenerConfig {
  ListenerConfig(..config, port:)
}

/// Set the database name.
pub fn database(config: ListenerConfig, database: String) -> ListenerConfig {
  ListenerConfig(..config, database:)
}

/// Set the username to connect as.
pub fn user(config: ListenerConfig, user: String) -> ListenerConfig {
  ListenerConfig(..config, user:)
}

/// Set the password for authentication.
pub fn password(config: ListenerConfig, password: Option(String)) -> ListenerConfig {
  ListenerConfig(..config, password:)
}

/// Set whether to use SSL.
pub fn ssl(config: ListenerConfig, ssl: Ssl) -> ListenerConfig {
  ListenerConfig(..config, ssl:)
}

/// Add a connection parameter.
pub fn connection_parameter(
  config: ListenerConfig,
  name name: String,
  value value: String,
) -> ListenerConfig {
  ListenerConfig(..config, connection_parameters: [
    #(name, value),
    ..config.connection_parameters
  ])
}

/// Set the IP version.
pub fn ip_version(config: ListenerConfig, ip_version: IpVersion) -> ListenerConfig {
  ListenerConfig(..config, ip_version:)
}

/// Start a notification listener process.
///
/// The listener will connect to PostgreSQL and maintain the connection,
/// automatically reconnecting with exponential backoff if disconnected.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(listener) =
///   notifications.default_config()
///   |> notifications.database("mydb")
///   |> notifications.user("postgres")
///   |> notifications.start()
/// ```
pub fn start(config: ListenerConfig) -> actor.StartResult(Listener) {
  case do_start(config) {
    Ok(pid) -> Ok(actor.Started(pid, Listener(pid)))
    Error(reason) -> Error(actor.InitExited(process.Abnormal(reason)))
  }
}

@external(erlang, "pog_ffi", "start_notifications")
fn do_start(config: ListenerConfig) -> Result(Pid, Dynamic)

/// Create a child specification for adding a notification listener to a
/// supervision tree.
///
/// ## Example
///
/// ```gleam
/// let config =
///   notifications.default_config()
///   |> notifications.database("mydb")
///   |> notifications.user("postgres")
///
/// supervision.new(supervision.OneForOne)
/// |> supervision.add(notifications.supervised(config))
/// |> supervision.start()
/// ```
pub fn supervised(config: ListenerConfig) -> supervision.ChildSpecification(Listener) {
  supervision.supervisor(fn() { start(config) })
}

/// Subscribe to notifications on a channel.
///
/// Returns a `Subscription` that can be used with `selecting` to receive
/// notifications, or with `unlisten` to unsubscribe.
///
/// Multiple processes can subscribe to the same channel, and each will
/// receive a copy of every notification.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(Listening(subscription)) =
///   notifications.listen(listener, "events")
/// ```
pub fn listen(listener: Listener, channel: String) -> Result(ListenResult, Nil) {
  do_listen(listener.pid, channel)
  |> result.map(fn(result) {
    case result {
      #(True, ref) -> Listening(Subscription(listener: listener.pid, ref: ref))
      #(False, ref) ->
        ListeningEventually(Subscription(listener: listener.pid, ref: ref))
    }
  })
}

@external(erlang, "pog_ffi", "listen")
fn do_listen(
  listener: Pid,
  channel: String,
) -> Result(#(Bool, Reference), Nil)

/// Unsubscribe from a channel.
///
/// After calling this, no more notifications will be received for this
/// subscription. If this was the last subscription to the channel, the
/// listener will send `UNLISTEN` to PostgreSQL.
///
/// ## Example
///
/// ```gleam
/// notifications.unlisten(subscription)
/// ```
pub fn unlisten(subscription: Subscription) -> Nil {
  do_unlisten(subscription.listener, subscription.ref)
}

@external(erlang, "pog_ffi", "unlisten")
fn do_unlisten(listener: Pid, ref: Reference) -> Nil

/// Add a handler to a selector for receiving notifications.
///
/// When a notification is received on the given subscription, the provided
/// mapper function will be called with the `Notification` and should return
/// a message of type `t`.
///
/// ## Example
///
/// ```gleam
/// type Message {
///   DbNotification(Notification)
///   // ... other messages
/// }
///
/// let selector =
///   process.new_selector()
///   |> notifications.selecting(subscription, DbNotification)
///
/// let message = process.select_forever(selector)
/// ```
pub fn selecting(
  selector: Selector(t),
  subscription: Subscription,
  mapper: fn(Notification) -> t,
) -> Selector(t) {
  selecting_notification(selector, subscription.listener, subscription.ref, mapper)
}

@external(erlang, "pog_ffi", "selecting_notification")
fn selecting_notification(
  selector: Selector(t),
  listener: Pid,
  ref: Reference,
  mapper: fn(Notification) -> t,
) -> Selector(t)
