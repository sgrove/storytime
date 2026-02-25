defmodule StorytimeWeb.StoryChannel do
  use StorytimeWeb, :channel

  @impl true
  def join("story:" <> story_id, _payload, socket) do
    {:ok, %{story_id: story_id, joined: true}, assign(socket, :story_id, story_id)}
  end

  @impl true
  def handle_in("update_story", payload, socket) do
    broadcast!(socket, "story_updated", %{story_id: socket.assigns.story_id, changes: payload})
    {:reply, {:ok, %{accepted: true}}, socket}
  end

  @impl true
  def handle_in("add_character", payload, socket) do
    broadcast!(socket, "character_added", %{story_id: socket.assigns.story_id, character: payload})
    {:reply, {:ok, %{accepted: true}}, socket}
  end

  @impl true
  def handle_in("update_character", payload, socket) do
    broadcast!(socket, "character_updated", %{story_id: socket.assigns.story_id, character: payload})
    {:reply, {:ok, %{accepted: true}}, socket}
  end

  @impl true
  def handle_in("delete_character", payload, socket) do
    broadcast!(socket, "character_deleted", %{story_id: socket.assigns.story_id, character: payload})
    {:reply, {:ok, %{accepted: true}}, socket}
  end

  @impl true
  def handle_in("add_page", payload, socket) do
    broadcast!(socket, "page_added", %{story_id: socket.assigns.story_id, page: payload})
    {:reply, {:ok, %{accepted: true}}, socket}
  end

  @impl true
  def handle_in("update_page", payload, socket) do
    broadcast!(socket, "page_updated", %{story_id: socket.assigns.story_id, page: payload})
    {:reply, {:ok, %{accepted: true}}, socket}
  end

  @impl true
  def handle_in("delete_page", payload, socket) do
    broadcast!(socket, "page_deleted", %{story_id: socket.assigns.story_id, page: payload})
    {:reply, {:ok, %{accepted: true}}, socket}
  end

  @impl true
  def handle_in("reorder_pages", payload, socket) do
    broadcast!(socket, "pages_reordered", %{story_id: socket.assigns.story_id, reorder: payload})
    {:reply, {:ok, %{accepted: true}}, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    broadcast!(socket, "event_received", %{event: event, payload: payload, story_id: socket.assigns.story_id})
    {:reply, {:ok, %{accepted: true, event: event}}, socket}
  end
end
