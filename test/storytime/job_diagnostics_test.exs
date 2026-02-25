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

  test "enriches scene jobs with full ordered character list" do
    now = DateTime.from_unix!(1_762_094_200)
    inserted_at = DateTime.add(now, -30, :second)

    story = %{
      characters: [
        %{id: "char-1", name: "Luna"},
        %{id: "char-2", name: "Milo"},
        %{id: "char-3", name: "Ari"}
      ],
      pages: [
        %{
          id: "page-1",
          page_index: 0,
          scene_description: "All heroes gather at the oak tree.",
          dialogue_lines: [
            %{id: "line-2", character_id: "char-2", sort_order: 2},
            %{id: "line-1", character_id: "char-1", sort_order: 1},
            %{id: "line-3", character_id: "char-2", sort_order: 3},
            %{id: "line-4", character_id: "char-3", sort_order: 4}
          ]
        }
      ],
      music_tracks: []
    }

    jobs = [
      %{
        id: "job-scene",
        job_type: :scene,
        target_id: "page-1",
        status: :running,
        error: nil,
        inserted_at: inserted_at,
        updated_at: inserted_at
      }
    ]

    [job] = JobDiagnostics.enrich(jobs, story, [], now)

    assert job.target_label == "Page 1 scene"
    assert job.scene_character_names == ["Luna", "Milo", "Ari"]
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

  test "flags long-running executing jobs as likely stuck" do
    now = DateTime.from_unix!(1_762_094_200)
    inserted_at = DateTime.add(now, -2_100, :second)

    jobs = [
      %{
        id: "job-running-stale",
        job_type: :headshot,
        target_id: "char-1",
        status: :running,
        error: nil,
        inserted_at: inserted_at,
        updated_at: inserted_at
      }
    ]

    oban_jobs = [
      %{
        id: 77,
        args: %{"generation_job_id" => "job-running-stale", "story_id" => "story-1"},
        state: "executing",
        queue: "generation",
        worker: "Storytime.Workers.ImageGenWorker",
        attempt: 1,
        max_attempts: 5,
        inserted_at: inserted_at,
        scheduled_at: inserted_at,
        attempted_at: inserted_at,
        completed_at: nil,
        cancelled_at: nil,
        discarded_at: nil,
        errors: []
      }
    ]

    [job] = JobDiagnostics.enrich(jobs, nil, oban_jobs, now)

    assert job.status == "running"
    assert job.likely_stuck == true
    assert job.stale_after_seconds == 900
    assert String.contains?(job.active_detail, "Likely stuck")
  end

  test "freezes age for completed jobs" do
    now = DateTime.from_unix!(1_762_094_200)
    inserted_at = DateTime.add(now, -120, :second)
    completed_at = DateTime.add(now, -45, :second)

    jobs = [
      %{
        id: "job-completed",
        job_type: :scene,
        target_id: "page-1",
        status: :completed,
        error: nil,
        inserted_at: inserted_at,
        updated_at: completed_at
      }
    ]

    [job_now] = JobDiagnostics.enrich(jobs, nil, [], now)
    [job_later] = JobDiagnostics.enrich(jobs, nil, [], DateTime.add(now, 30, :second))

    assert job_now.status == "completed"
    assert job_now.age_seconds == 75
    assert job_later.age_seconds == 75
  end

  test "freezes age for failed discarded jobs" do
    now = DateTime.from_unix!(1_762_094_200)
    inserted_at = DateTime.add(now, -140, :second)
    discarded_at = DateTime.add(now, -20, :second)

    jobs = [
      %{
        id: "job-failed",
        job_type: :dialogue_tts,
        target_id: "line-9",
        status: :pending,
        error: nil,
        inserted_at: inserted_at,
        updated_at: inserted_at
      }
    ]

    oban_jobs = [
      %{
        id: 101,
        args: %{"generation_job_id" => "job-failed", "story_id" => "story-1"},
        state: "discarded",
        queue: "generation",
        worker: "Storytime.Workers.TtsGenWorker",
        attempt: 6,
        max_attempts: 6,
        inserted_at: inserted_at,
        scheduled_at: inserted_at,
        attempted_at: discarded_at,
        completed_at: nil,
        cancelled_at: nil,
        discarded_at: discarded_at,
        errors: [%{"error" => "final provider failure"}]
      }
    ]

    [job_now] = JobDiagnostics.enrich(jobs, nil, oban_jobs, now)
    [job_later] = JobDiagnostics.enrich(jobs, nil, oban_jobs, DateTime.add(now, 45, :second))

    assert job_now.status == "failed"
    assert job_now.age_seconds == 120
    assert job_later.age_seconds == 120
  end
end
