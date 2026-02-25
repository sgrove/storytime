defmodule Storytime.Workers.DeployWorkerTest do
  use ExUnit.Case, async: true

  alias Storytime.Workers.DeployWorker

  test "non_retryable_reason identifies validation/configuration failures" do
    assert DeployWorker.non_retryable_reason?(:missing_render_api_key)
    assert DeployWorker.non_retryable_reason?(:reader_template_not_found)
    assert DeployWorker.non_retryable_reason?(:subdomain_taken)
    assert DeployWorker.non_retryable_reason?(:render_service_shape_invalid)
    assert DeployWorker.non_retryable_reason?({:missing_field, "subdomain"})
    assert DeployWorker.non_retryable_reason?({:render_create_service_failed, 422, %{}})
    assert DeployWorker.non_retryable_reason?({:deploy_failed, %{status: "failed"}})

    refute DeployWorker.non_retryable_reason?(:deploy_timeout)
    refute DeployWorker.non_retryable_reason?({:render_trigger_deploy_failed, 503, %{}})
  end

  test "failure_details returns structured metadata for operator diagnostics" do
    details =
      DeployWorker.failure_details({:render_create_service_failed, 422, %{"error" => "bad"}})

    assert details.code == "render_create_service_failed"
    assert details.category == "validation_or_configuration"
    assert details.retryable == false
    assert is_binary(details.message)

    timeout_details = DeployWorker.failure_details(:deploy_timeout)
    assert timeout_details.code == "deploy_timeout"
    assert timeout_details.category == "timeout"
    assert timeout_details.retryable == true
  end
end
