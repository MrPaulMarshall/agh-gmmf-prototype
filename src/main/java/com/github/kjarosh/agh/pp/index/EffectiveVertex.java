package com.github.kjarosh.agh.pp.index;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.github.kjarosh.agh.pp.graph.model.Edge;
import com.github.kjarosh.agh.pp.graph.model.Permissions;
import com.github.kjarosh.agh.pp.graph.model.VertexId;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.security.Permission;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.Future;
import java.util.stream.Collectors;

/**
 * @author Kamil Jarosz
 */
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class EffectiveVertex {
    @JsonProperty("dirty")
    boolean dirty = false;
    @JsonProperty("effectivePermissions")
    Permissions effectivePermissions = Permissions.NONE;
    @JsonProperty("intermediateVertices")
    Set<VertexId> intermediateVertices = new HashSet<>();

    @JsonIgnore
    public Set<VertexId> getIntermediateVerticesEager() {
        return getIntermediateVertices();
    }

    @JsonIgnore
    public boolean getAndSetDirty(boolean dirty) {
        boolean old = this.dirty;
        this.dirty = dirty;
        return old;
    }

    @JsonIgnore
    public void addIntermediateVertex(VertexId id, Runnable modifyListener) {
        addIntermediateVertices(Collections.singleton(id), modifyListener);
    }

    @JsonIgnore
    public void addIntermediateVertices(Set<VertexId> ids, Runnable modifyListener) {
        if (getIntermediateVertices().addAll(ids)) {
            modifyListener.run();
        }
    }

    @JsonIgnore
    public void removeIntermediateVertex(VertexId id, Runnable modifyListener) {
        removeIntermediateVertices(Collections.singleton(id), modifyListener);
    }

    @JsonIgnore
    public void removeIntermediateVertices(Set<VertexId> ids, Runnable modifyListener) {
        if (getIntermediateVertices().removeAll(ids)) {
            modifyListener.run();
        }
    }

    @JsonIgnore
    public CompletionStage<RecalculationResult> recalculatePermissions(Set<Edge> edgesToCalculate) {
        CalculationResult result = calculatePermissions(edgesToCalculate);
        boolean wasDirty = getDirtyAndSetResult(result);
        if (result.isDirty()) {
            return CompletableFuture.completedFuture(RecalculationResult.DIRTY);
        } else if (wasDirty) {
            return CompletableFuture.completedFuture(RecalculationResult.CLEANED);
        } else {
            return CompletableFuture.completedFuture(RecalculationResult.CLEAN);
        }
    }

    protected boolean getDirtyAndSetResult(CalculationResult result) {
        boolean wasDirty = isDirty();
        setDirty(result.isDirty());
        setEffectivePermissions(result.getCalculated());
        return wasDirty;
    }

    protected CalculationResult calculatePermissions(Set<Edge> edgesToCalculate) {
        Set<VertexId> intermediateVertices = getIntermediateVerticesEager();
        List<Permissions> perms = edgesToCalculate.stream()
                .filter(x -> intermediateVertices.contains(x.src()))
                .map(Edge::permissions)
                .collect(Collectors.toList());
        Permissions effectivePermissions = perms.stream()
                .reduce(Permissions.NONE, Permissions::combine);
        boolean dirty = perms.size() != intermediateVertices.size();
        return CalculationResult.builder()
                .calculated(effectivePermissions)
                .dirty(dirty)
                .build();
    }

    @Override
    public String toString() {
        return "EffectiveVertex(" + effectivePermissions +
                " by " + intermediateVertices + ')';
    }

    public enum RecalculationResult {
        CLEAN,
        CLEANED,
        DIRTY,
    }

    @Getter
    @Builder
    protected static class CalculationResult {
        Permissions calculated;
        boolean dirty;
    }
}
