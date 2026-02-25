defmodule Storytime.JobDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Storytime.JobDiagnostics

  test "enriches pending dialogue_tts jobs with target context and queue metadata" do
    now = DateTime.from_unix!(1_762_094_200)

    story = %{
      characters: [%{id: "char-1", name: "Luna"}],
      pages: [
        %{
          id: "page-1",
          page_index: 0,
          narration_text: "Moonlight in the garden",
          dialogue_lines: [
            %{id: "line-1", character_id: "char-1", text: "I found the glowing acorn!"}
          ]
        }
      ],
      music_tracks: []
    }

    older = DateTime.add(now, -90, :second)
    newer = DateTime.add(now, -20, :second)

    jobs = [
      %{
        id: "job-2",
        job_type: :dialogue_tts,
        target_id: "line-1",
        status: :pending,
        error: nil,
        inserted_at: newer,
        updated_at: newer
      },
      %{
        id: "job-1",
        job_type: :dialogue_tts,
        target_id: "line-1",
        status: :pending,
        error: nil,
        inserted_at: older,
        updated_at: older
      }
    ]

    oban_jobs = [
      %{
        id: 100,
        args: %{"generation_job_id" => "job-1", "story_id" => "story-1"},
        state: "available",
        queue: "generation",
        worker: "Storytime.Workers.TtsGenWorker",
        attempt: 1,
        max_attempts: 6,
        inserted_at: older,
        scheduled_at: older,
        attempted_at: nil,
        completed_at: nil,
        cancelled_at: nil,
        discarded_at: nil,
        errors: []
      }
    ]

    [newest, oldest] = JobDiagnostics.enrich(jobs, story, oban_jobs, now)

    assert newest.id == "job-2"
    assert newest.queue_position == 2

    assert oldest.id == "job-1"
    assert oldest.queue_position == 1
    assert oldest.target_label == "Page 1 dialogue"
    assert oldest.character_name == "Luna"
    assert oldest.text_preview == "I found the glowing acorn!"
    assert oldest.age_seconds == 90
    assert oldest.active_detail == "Waiting in queue at position 1."
    assert oldest.oban.state == "available"
    assert oldest.oban.attempt == 1
    assert oldest.oban.max_attempts == 6
  end

  test "shows retry timing when oban marks a pending job as retryable" do
    now = DateTime.from_unix!(1_762_094_200)
    scheduled_at = DateTime.add(now, 45, :second)

    jobs = [
      %{
        id: "job-retry",
        job_type: :dialogue_tts,
        target_id: "line-2",
        status: :pending,
        error: nil,
        inserted_at: now,
        updated_at: now
      }
    ]

    oban_jobs = [
      %{
        id: 42,
        args: %{"generation_job_id" => "job-retry", "story_id" => "story-1"},
        state: "retryable",
        queue: "generation",
        worker: "Storytime.Workers.TtsGenWorker",
        attempt: 3,
        max_attempts: 6,
        inserted_at: now,
        scheduled_at: scheduled_at,
        attempted_at: now,
        completed_at: nil,
        cancelled_at: nil,
        discarded_at: nil,
        errors: [%{"error" => "timeout from provider"}]
      }
    ]

    [job] = JobDiagnostics.enrich(jobs, nil, oban_jobs, now)

    assert job.active_detail == "Queued for retry in about 45s."
    assert job.oban.available_in_seconds == 45
    assert job.oban.errors_count == 1
    assert job.oban.last_error == "timeout from provider"
  end

  test "marks pending jobs as failed when oban is discarded" do
    now = DateTime.from_unix!(1_762_094_200)

    jobs = [
      %{
        id: "job-discarded",
        job_type: :dialogue_tts,
        target_id: "line-2",
        status: :pending,
        error: nil,
        inserted_at: now,
        updated_at: now
      }
    ]

    oban_jobs = [
      %{
        id: 99,
        args: %{"generation_job_id" => "job-discarded", "story_id" => "story-1"},
        state: "discarded",
        queue: "generation",
        worker: "Storytime.Workers.TtsGenWorker",
        attempt: 6,
        max_attempts: 6,
        inserted_at: now,
        scheduled_at: now,
        attempted_at: now,
        completed_at: nil,
        cancelled_at: nil,
        discarded_at: now,
        errors: [%{"error" => "voice lookup failed"}]
      }
    ]

    [job] = JobDiagnostics.enrich(jobs, nil, oban_jobs, now)

    assert job.status == "failed"

    assert job.active_detail ==
             "Worker exhausted retries. Retry this job to enqueue a fresh attempt."
  end
end
