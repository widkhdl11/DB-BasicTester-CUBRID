#!/bin/bash


## 프로세스 동시성으로 INSERT 문 누락 테스트
# CUBRID의 MVCC기법으로 INSERT문 누락이 없음
test_concurrent_inserts() {
    log_message "INFO" "동시성 INSERT 테스트 시작"
    start_timer
    reset_tables "users" "orders"
    
    # 성공/실패 카운터
    local success=0
    local failed=0
    local pids=()
    local actual_count=0
    local error_msg=""
    local json=""
    local query_result=""

    reset_tables "orders" "users"
    
    # 3개 프로세스 동시 실행
    for i in {1..10}; do
        query_result=$(run_query "INSERT INTO users (name, email, age) VALUES ('Concurrent$i', 'c$i@test.com', $((25+i)));") &
        pids[$i]=$!
    done
    
    # 각 프로세스 결과 확인
    for i in {1..10}; do
        wait ${pids[$i]}
        result=$?
        if [ $result -eq 0 ]; then
            success=$((success + 1))
        else
            if [[ $query_result == "Error: database is locked" ]]; then 
                echo "❌ 예상치 못한 에러 발생: $query_result"  
                break
            fi
            failed=$((failed + 1))
            echo "⚠️  프로세스 $i 실패 (exit code: $result)"
        fi
    done
    
    echo "성공: $success, 실패: $failed"
    
    actual_count=$(assert_count "SELECT COUNT(*) FROM users WHERE name LIKE 'Concurrent%';" "$success")
    # 검증: 성공한 개수와 DB 레코드 수가 일치해야 함
    if [ 10 -eq "$success" ]; then
        echo "❌ 동시성 테스트 실패"
        error_msg="실패 없이 모두 성공해버림"
        result=1
    elif [ "$actual_count" -eq "$success" ]; then
        echo "✅ 동시성 테스트 통과"
        result=0
    else
        echo "❌ 데이터 불일치 발생!"
        error_msg="데이터 불일치(success_count=$success / failed_count=$failed)"
        result=1
    fi
    execution_time=$(end_timer) 

    json=$(make_json "success_count=$success" "failed_count=$failed" )
    log_test_result "동시성 INSERT 테스트" "$result" "$execution_time" "$json" "$error_msg"

}

# 데이터베이스 동시성으로 인해 데이터베이스 값 유실 테스트
test_update_conflicts() {
    log_message "INFO" "Lost Update 테스트 시작"
    start_timer
    reset_tables "orders" "users"
    setup_data

    local pids=()    
    local error_msg=""
    local json=""
    local query_result=""
    local age=0
    local success=0
    local final_age=0
    local expected_age=0

    update_separated() {
        age=$(run_transaction "SELECT age FROM users WHERE name='test1';" | tail -n 1)
        # age=$(echo "$raw_output" | grep -oE "[0-9]+" | head -n 1)

        (( age++ ))
        
        sleep 0.1
        run_query "UPDATE users SET age=$age WHERE name='test1';"
        return $?
    }
    
    for i in {1..3}; do
        update_separated &
        pids[$i]=$!
        sleep 0.1
    done
    
    # 대기
    for i in {1..3}; do
        wait ${pids[$i]}
        [ $? -eq 0 ] && success=$((success + 1))
    done
    
    final_age=$(run_query "SELECT age FROM users WHERE name='test1';" | tail -n 1)
    expected_age=$(( 25+success ))

    echo "성공한 프로세스: $success"
    echo "최종 age: $final_age"
    echo "기대 age: $expected_age"
    
    if [ "$final_age" -lt "$expected_age" ]; then
        result=0
        echo "✅ 테스트 성공 (Lost Update 발생)"
        echo "   손실: $((25 + success - final_age))번"
    else
        result=1
        echo "❌ 테스트 실패(데이터 손실 발생하지 않음)"
        error_msg="데이터 손실 발생하지 않음"
    fi
    execution_time=$(end_timer) 

    json=$(make_json "query_attempts_count=5" "success_query_count=$success" "expected_age=$expected_age" "actual_age=$final_age")
    log_test_result "동시성 INSERT 테스트" "$result" "$execution_time" "$json" "$error_msg"

}


# IMMEDIATE를 사용하여 동시성으로 인한 코드 누락 방지 테스트
# CUBRID의 시스템으로 인해 타임아웃 발생하지 않음
test_timeout_detection() {
    log_message "INFO" "Lock Timeout 테스트 시작"
    start_timer
    reset_tables "users" "orders"
    
    # ✅ 초기 데이터 (충돌 대상)
    run_query "INSERT INTO users (name, email, age) VALUES ('TestUser', 'test@test.com', 30);"
    
    local error_msg=""
    local json=""
    local pid1 pid2
    local result1 result2
    local long_output short_output
    
    # 긴 트랜잭션 (같은 행을 5초간 락)
    long_output=$(run_transaction "UPDATE users SET age=40 WHERE name='TestUser';
    SELECT SLEEP(5);
    COMMIT;
    ") &
    pid1=$!
    
    echo "긴 트랜잭션 시작 (PID: $pid1)" >&2
    sleep 1  # 긴 트랜잭션이 락을 확실히 획득하도록
    
    # 짧은 트랜잭션 (같은 행 수정 시도 → 타임아웃!)
    short_output=$(run_transaction "
    UPDATE users SET age=50 WHERE name='TestUser';
    COMMIT;
    ") &
    pid2=$!
    
    echo "짧은 트랜잭션 시작 (PID: $pid2)" >&2
    
    # 대기
    wait $pid1
    result1=$?
    wait $pid2
    result2=$?
    
    echo "=== 긴 트랜잭션 결과 ===" >&2
    echo "Exit code: $result1" >&2
    echo "$long_output" >&2
    
    echo "=== 짧은 트랜잭션 결과 ===" >&2
    echo "Exit code: $result2" >&2
    echo "$short_output" >&2
    
    # 최종 age 확인
    final_age=$(run_query "SELECT age FROM users WHERE name='TestUser';" | tail -n 1)
    echo "최종 age: $final_age" >&2
    
    execution_time=$(end_timer)
    
    # 검증
    if [ $result2 -ne 0 ]; then
        # 짧은 트랜잭션이 실패했으면 성공!
        if echo "$short_output" | grep -q -i "timeout\|lock\|wait"; then
            result=0
            echo "✅ Lock Timeout 발생! (데이터 정확성 보장)" >&2
            json=$(make_json long_success=true short_success=false final_age=$final_age reason="lock_timeout")
        else
            result=1
            echo "❌ 다른 이유로 실패" >&2
            error_msg="예상치 못한 에러: $short_output"
            json=$(make_json long_success=true short_success=false final_age=$final_age)
        fi
    elif [ $result1 -eq 0 ] && [ $result2 -eq 0 ]; then
        result=1
        echo "❌ 두 트랜잭션 모두 성공 (Lock Timeout 미발생)" >&2
        error_msg="타임아웃 미발생 - CUBRID가 순차 처리함"
        json=$(make_json long_success=true short_success=true final_age=$final_age)
    else
        result=1
        echo "❌ 긴 트랜잭션 실패" >&2
        error_msg="긴 트랜잭션이 실패함"
        json=$(make_json long_success=false short_success=$result2 final_age=$final_age)
    fi
    
    log_test_result "Lock Timeout 테스트" "$result" "$execution_time" "$json" "$error_msg"
}