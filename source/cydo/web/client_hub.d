module cydo.web.client_hub;

import std.algorithm : remove;
import std.string : representation;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;

class ClientHub
{
	private WebSocketAdapter[] clients;
	/// Per-client subscription set: which tasks each client receives live events for.
	/// INVARIANT: task history is authoritative; live delivery is only an
	/// optimization for clients that have caught up. request_history synchronously
	/// enqueues the replay through task_history_end, then marks the client
	/// subscribed. Later live sends enqueue behind that replay on the same socket,
	/// so clients process the task_history_end boundary before later live
	/// events regardless of link or browser speed. Every task_reload is a hard
	/// history-lineage boundary: clients are unsubscribed and must re-subscribe via
	/// request_history.
	private bool[int][WebSocketAdapter] clientSubscriptions;

	void add(WebSocketAdapter ws)
	{
		clients ~= ws;
	}

	void remove(WebSocketAdapter ws)
	{
		clients = clients.remove!(c => c is ws);
		clientSubscriptions.remove(ws);
	}

	WebSocketAdapter[] snapshotClients()
	{
		return clients.dup;
	}

	void subscribe(WebSocketAdapter ws, int tid)
	{
		clientSubscriptions.require(ws)[tid] = true;
	}

	void unsubscribeAll(int tid)
	{
		foreach (ws; clients)
			if (auto subs = ws in clientSubscriptions)
				(*subs).remove(tid);
	}

	void sendToSubscribed(int tid, Data payload)
	{
		foreach (ws; clients)
			if (auto subs = ws in clientSubscriptions)
				if (tid in *subs)
					ws.send(payload);
	}

	void sendToSubscribedExcept(int tid, WebSocketAdapter excludedWs, Data payload)
	{
		foreach (ws; clients)
			if (ws !is excludedWs)
				if (auto subs = ws in clientSubscriptions)
					if (tid in *subs)
						ws.send(payload);
	}

	void broadcast(string payload)
	{
		auto data = Data(payload.representation);
		foreach (ws; clients)
			ws.send(data);
	}

	bool hasSubscribers(int tid)
	{
		foreach (ws; clients)
			if (auto subs = ws in clientSubscriptions)
				if (tid in *subs)
					return true;
		return false;
	}
}

unittest
{
	import ae.net.asockets : ConnectionState, DisconnectType, IConnection;
	import ae.sys.dataset : joinData;
	import ae.utils.array : as;

	alias ConnectHandler = void delegate();
	alias ReadDataHandler = void delegate(Data);
	alias DisconnectHandler = void delegate(string, DisconnectType);
	alias BufferFlushedHandler = void delegate();

	class StubWebSocketAdapter : WebSocketAdapter
	{
		string[] sent;

		this()
		{
			super(new class IConnection
			{
				ConnectionState state_ = ConnectionState.connected;
				DisconnectHandler disconnectHandler;

				@property ConnectionState state() { return state_; }
				void send(scope Data[] data, int priority) {}
				void disconnect(string reason, DisconnectType type)
				{
					state_ = ConnectionState.disconnected;
					disconnectHandler(reason, type);
				}
				@property void handleConnect(ConnectHandler value) {}
				@property void handleReadData(ReadDataHandler value) {}
				@property void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; }
				@property void handleBufferFlushed(BufferFlushedHandler value) {}
			});
		}

		override void send(scope Data[] data, int priority)
		{
			sent ~= cast(string) data.joinData().toGC().as!string;
		}
	}

	auto hub = new ClientHub();
	auto excluded = new StubWebSocketAdapter();
	auto included = new StubWebSocketAdapter();
	auto otherTid = new StubWebSocketAdapter();
	scope(exit)
	{
		excluded.disconnect("test complete", DisconnectType.requested);
		included.disconnect("test complete", DisconnectType.requested);
		otherTid.disconnect("test complete", DisconnectType.requested);
	}
	hub.add(excluded);
	hub.add(included);
	hub.add(otherTid);
	hub.subscribe(excluded, 7);
	hub.subscribe(included, 7);
	hub.subscribe(otherTid, 9);

	hub.sendToSubscribedExcept(7, excluded, Data("payload".representation));

	assert(excluded.sent.length == 0);
	assert(included.sent.length == 1);
	assert(included.sent[0] == "payload");
	assert(otherTid.sent.length == 0);
}
