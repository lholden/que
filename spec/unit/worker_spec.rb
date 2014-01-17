require 'spec_helper'

describe Que::Worker do
  before do
    @job_queue    = Que::SortedQueue.new
    @result_queue = Que::ThreadSafeArray.new

    @worker = Que::Worker.new :job_queue    => @job_queue,
                              :result_queue => @result_queue
  end

  it "should repeatedly work jobs that are passed to it via its job_queue, ordered correctly" do
    begin
      $results = []

      class WorkerJob < Que::Job
        def run(number)
          $results << number
        end
      end

      jobs = [1, 2, 3].map do |i|
        WorkerJob.new :priority => i,
                      :run_at   => Time.now,
                      :job_id   => i,
                      :args     => "[#{i}]"
      end

      jobs.shuffle!

      @job_queue.insert(jobs)
      sleep_until { $results.count == 3 }

      $results.should == [1, 2, 3]
      @result_queue.to_a.should == [1, 2, 3]
    ensure
      $results = nil
    end
  end

  it "should pass a job's arguments to the run method and delete it from the database" do
    ArgsJob.queue 1, 'two', {'three' => 3}
    DB[:que_jobs].count.should be 1

    job = ArgsJob.new(Que.execute("SELECT * FROM que_jobs").first)
    @job_queue.insert(job)
    sleep_until { @result_queue.to_a.count == 1 }

    DB[:que_jobs].count.should be 0
    $passed_args.should == [1, 'two', {'three' => 3}]
  end

  it "should make it easy to destroy the job within the same transaction as other changes" do
    class DestroyJob < Que::Job
      def run
        destroy
      end
    end

    DestroyJob.queue
    DB[:que_jobs].count.should be 1

    job = DestroyJob.new(Que.execute("SELECT * FROM que_jobs").first)
    @job_queue.insert(job)
    sleep_until { @result_queue.to_a.count == 1 }

    DB[:que_jobs].count.should be 0
  end

  it "should make a job's argument hashes indifferently accessible" do
    DB[:que_jobs].count.should be 0
    ArgsJob.queue 1, 'two', {'array' => [{'number' => 3}]}
    DB[:que_jobs].count.should be 1

    job = ArgsJob.new(Que.execute("SELECT * FROM que_jobs").first)
    @job_queue.insert(job)
    sleep_until { @result_queue.to_a.count == 1 }

    DB[:que_jobs].count.should be 0
    $passed_args.last[:array].first[:number].should == 3
  end

  describe "when an error is raised" do
    it "should not crash the worker" do
      job_1 = ErrorJob.new :priority => 1,
                           :run_at   => Time.now,
                           :job_id   => 1,
                           :args     => '[]'

      job_2 = Que::Job.new :priority => 2,
                           :run_at   => Time.now,
                           :job_id   => 2,
                           :args     => '[]'

      @job_queue.insert [job_1, job_2].shuffle

      sleep_until { @result_queue.to_a.count == 2 }

      @result_queue.to_a.should == [1, 2]
    end

    it "should pass it to the error handler" do
      begin
        error = nil
        Que.error_handler = proc { |e| error = e }

        job = ErrorJob.new :priority => 1,
                           :run_at   => Time.now,
                           :job_id   => 1,
                           :args     => '[]'

        @job_queue.insert job

        sleep_until { @result_queue.to_a.count == 1 }

        @result_queue.to_a.should == [1]
      ensure
        error.should be_an_instance_of RuntimeError
        error.message.should == "ErrorJob!"

        Que.error_handler = nil
      end
    end

    it "but the error handler is problematic should not crash the worker" do
      begin
        Que.error_handler = proc { |e| raise "Error handler error!" }

        job_1 = ErrorJob.new :priority => 1,
                             :run_at   => Time.now,
                             :job_id   => 1,
                             :args     => '[]'

        job_2 = Que::Job.new :priority => 2,
                             :run_at   => Time.now,
                             :job_id   => 2,
                             :args     => '[]'

        @job_queue.insert [job_1, job_2].shuffle

        sleep_until { @result_queue.to_a.count == 2 }

        @result_queue.to_a.should == [1, 2]
      ensure
        Que.error_handler = nil
      end
    end
  end
end
