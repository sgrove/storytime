defmodule Storytime.Deploy.RenderDeployTest do
  use ExUnit.Case, async: true

  alias Storytime.Deploy.RenderDeploy

  describe "unwrap_deploy/1" do
    test "accepts wrapped deploy shape" do
      assert {:ok, %{"status" => "build_in_progress"} = deploy} =
               RenderDeploy.unwrap_deploy(%{"deploy" => %{"status" => "build_in_progress"}})

      assert deploy["status"] == "build_in_progress"
    end

    test "accepts top-level deploy shape" do
      assert {:ok, %{"status" => "live"} = deploy} =
               RenderDeploy.unwrap_deploy(%{"id" => "dep-1", "status" => "live"})

      assert deploy["id"] == "dep-1"
    end

    test "rejects invalid response shape" do
      assert {:error, :invalid_deploy_response} = RenderDeploy.unwrap_deploy(%{"foo" => "bar"})
      assert {:error, :invalid_deploy_response} = RenderDeploy.unwrap_deploy([])
    end
  end

  describe "classify_deploy_status/1" do
    test "classifies live status" do
      assert :live = RenderDeploy.classify_deploy_status("live")
      assert :live = RenderDeploy.classify_deploy_status("deployed")
      assert :live = RenderDeploy.classify_deploy_status("succeeded")
    end

    test "classifies known terminal failures" do
      assert :failed = RenderDeploy.classify_deploy_status("build_failed")
      assert :failed = RenderDeploy.classify_deploy_status("failed")
      assert :failed = RenderDeploy.classify_deploy_status("update_failed")
      assert :failed = RenderDeploy.classify_deploy_status("canceled")
      assert :failed = RenderDeploy.classify_deploy_status("cancelled")
      assert :failed = RenderDeploy.classify_deploy_status("deactivated")
      assert :failed = RenderDeploy.classify_deploy_status("pre_deploy_failed")
      assert :failed = RenderDeploy.classify_deploy_status("timed_out")
      assert :failed = RenderDeploy.classify_deploy_status("timeout")
      assert :failed = RenderDeploy.classify_deploy_status("build_timed_out")
      assert :failed = RenderDeploy.classify_deploy_status("deploy_failed")
    end

    test "classifies non-terminal statuses as pending" do
      assert :pending = RenderDeploy.classify_deploy_status("build_in_progress")
      assert :pending = RenderDeploy.classify_deploy_status("created")
      assert :pending = RenderDeploy.classify_deploy_status("pre_deploy_in_progress")
    end

    test "rejects missing status" do
      assert :invalid = RenderDeploy.classify_deploy_status(nil)
      assert :invalid = RenderDeploy.classify_deploy_status("")
      assert :invalid = RenderDeploy.classify_deploy_status(123)
    end
  end

  describe "owner_story_id_from_env_vars/1" do
    test "prefers STORYTIME_STORY_ID and falls back to VITE_STORY_ID" do
      env_vars = [
        %{"envVar" => %{"key" => "VITE_STORY_ID", "value" => "story-vite"}},
        %{"envVar" => %{"key" => "STORYTIME_STORY_ID", "value" => "story-owned"}}
      ]

      assert "story-owned" = RenderDeploy.owner_story_id_from_env_vars(env_vars)
    end

    test "returns nil for missing or malformed env var rows" do
      assert is_nil(RenderDeploy.owner_story_id_from_env_vars([]))
      assert is_nil(RenderDeploy.owner_story_id_from_env_vars([%{"foo" => "bar"}]))
      assert is_nil(RenderDeploy.owner_story_id_from_env_vars(nil))
    end
  end

  describe "availability_for_story/2" do
    test "classifies owned and taken subdomains" do
      assert :owned = RenderDeploy.availability_for_story("story-1", "story-1")
      assert :taken = RenderDeploy.availability_for_story("story-2", "story-1")
      assert :taken = RenderDeploy.availability_for_story(nil, "story-1")
    end
  end
end
