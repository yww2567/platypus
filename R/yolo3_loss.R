#' Transforms `Yolo3` predictions into valid box coordinates/scores.
#' @description Transforms `Yolo3` predictions into valid box coordinates/scores.
#' @import tensorflow
#' @import keras
#' @param preds \code{\link[platypus]{yolo3}} model predictions (from one grid).
#' @param anchors Prediction anchors (for one grid). For exact format check \code{\link[platypus]{coco_anchors}}.
#' @param n_class Number of prediction classes.
#' @param transform_proba Logical. Should the score/class probabilities be transformed.
#' @return Transformed bounding box coordinates/scores.
transform_boxes_tf <- function(preds, anchors, n_class, transform_proba = TRUE) {
  grid_h <- preds$get_shape()$as_list()[[2]]
  grid_w <- preds$get_shape()$as_list()[[3]]
  box_split <- tf$split(preds, num_or_size_splits = as.integer(c(1, 1, 1, 1, 1, n_class)), axis = as.integer(-1))
  box_x <- k_sigmoid(box_split[[1]])
  box_y <- k_sigmoid(box_split[[2]])
  box_w <- box_split[[3]]
  box_h <- box_split[[4]]
  score <- if (transform_proba) k_sigmoid(box_split[[5]]) else box_split[[5]]
  class_probs <- if (transform_proba) k_sigmoid(box_split[[6]]) else box_split[[6]]
  pred_box <- k_concatenate(list(box_x, box_y, box_w, box_h), axis = as.integer(-1))

  grid <- tf$meshgrid(tf$range(grid_w), tf$range(grid_h))
  grid_col <- tf$expand_dims(tf$expand_dims(grid[[1]], axis = as.integer(-1)), axis = as.integer(-1))
  grid_row <- tf$expand_dims(tf$expand_dims(grid[[2]], axis = as.integer(-1)), axis = as.integer(-1))

  box_x = (box_x + tf$cast(grid_col, tf$float32)) /  tf$cast(grid_w, tf$float32)
  box_y = (box_y + tf$cast(grid_row, tf$float32)) /  tf$cast(grid_h, tf$float32)

  anchors_tf <- tf$constant(anchors, tf$float32)
  anchors_tf <- tf$expand_dims(tf$expand_dims(anchors_tf, axis = as.integer(0)), axis = as.integer(0))
  anchors_tf <- tf$split(anchors_tf, num_or_size_splits = as.integer(c(1, 1)), axis = as.integer(-1))
  box_w <- k_exp(box_w) * anchors_tf[[1]]
  box_h <- k_exp(box_h) * anchors_tf[[2]]

  bbox <- k_concatenate(list(box_x, box_y, box_w, box_h), axis = as.integer(-1))
  list(bbox, score, class_probs)
}

#' Transforms boxes to min/max coordinates.
#' @description Transforms boxes to min/max coordinates.
#' @import tensorflow
#' @import keras
#' @param box Boxes coordinates.
#' @return Boxes min/max coordinates.
transform_box_to_min_max <- function(box) {
  box_xmin <- tf$expand_dims(box[ , , , , 1] - box[ , , , , 3] / 2, axis = as.integer(-1))
  box_ymin <- tf$expand_dims(box[ , , , , 2] - box[ , , , , 4] / 2, axis = as.integer(-1))
  box_xmax <- tf$expand_dims(box[ , , , , 1] + box[ , , , , 3] / 2, axis = as.integer(-1))
  box_ymax <- tf$expand_dims(box[ , , , , 2] + box[ , , , , 4] / 2, axis = as.integer(-1))
  k_concatenate(list(box_xmin, box_ymin, box_xmax, box_ymax), axis = as.integer(-1))
}

#' Calculates boxes IoU.
#' @description Calculates boxes IoU.
#' @import tensorflow
#' @import keras
#' @param pred_boxes Tensor of predicted coordinates.
#' @param true_boxes Tensor of true coordinates.
#' @return IoU between true and predicted boxes.
calculate_iou <- function(pred_boxes, true_boxes) {
  intersection_w <- tf$maximum(tf$minimum(pred_boxes[ , , , , 3], true_boxes[ , , , , 3]) -
                                 tf$maximum(pred_boxes[ , , , , 1], true_boxes[ , , , , 1]), 0)
  intersection_h <- tf$maximum(tf$minimum(pred_boxes[ , , , , 4], true_boxes[ , , , , 4]) -
                                 tf$maximum(pred_boxes[ , , , , 2], true_boxes[ , , , , 2]), 0)
  intersection_area <- intersection_w * intersection_h
  pred_boxes_area <- (pred_boxes[ , , , , 3] - pred_boxes[ , , , , 1]) *
    (pred_boxes[ , , , , 4] - pred_boxes[ , , , , 2])
  true_boxes_area = (true_boxes[ , , , , 3] - true_boxes[ , , , , 1]) *
    (true_boxes[ , , , , 4] - true_boxes[ , , , , 2])
  intersection_area / (pred_boxes_area + true_boxes_area - intersection_area)
}

#' Compares boxes by IoU.
#' @description Compares boxes by IoU.
#' @import tensorflow
#' @import keras
#' @param pred_boxes Tensor of predicted coordinates.
#' @param true_boxes Tensor of true coordinates.
#' @return Max IoU between true and predicted boxes.
get_max_boxes_iou <- function(pred_boxes, true_boxes) {
  pred_boxes <- tf$expand_dims(pred_boxes, as.integer(-2))
  true_boxes <- tf$expand_dims(true_boxes, as.integer(0))

  new_shape <- tf$broadcast_dynamic_shape(tf$shape(pred_boxes), tf$shape(true_boxes))
  pred_boxes <- tf$broadcast_to(pred_boxes, new_shape)
  true_boxes <- tf$broadcast_to(true_boxes, new_shape)

  calculate_iou(pred_boxes, true_boxes)
}

#' Calculates loss for one `Yolo3` grid.
#' @description Calculates loss for one `Yolo3` grid.
#' @import tensorflow
#' @import keras
#' @param y_true Tensor of true coordinates/scores.
#' @param y_pred Tensor of predicted coordinates/scores.
#' @param anchors Prediction anchors (for one grid). For exact format check \code{\link[platypus]{coco_anchors}}.
#' @param n_class Number of prediction classes.
#' @param nonobj_threshold Non-object ignore threshold.
#' @param bbox_lambda Bounding box loss lambda.
#' @param obj_lambda Object loss lambda.
#' @param noobj_lambda Nonobject loss lambda.
#' @param class_lambda Class loss lambda.
#' @param class_weights Vector of length `n_class` with class weights.
#' @return Loss for one `Yolo3` grid.
#' @export
yolo3_grid_loss <- function(y_true, y_pred, anchors, n_class, nonobj_threshold,
                            bbox_lambda = 1, obj_lambda = 1, noobj_lambda = 1,
                            class_lambda = 1, class_weights = rep(1, n_class)) {
  true_boxes <- transform_boxes_tf(y_true, anchors, n_class, transform_proba = FALSE)
  pred_boxes <- transform_boxes_tf(y_pred, anchors, n_class, transform_proba = TRUE)
  true_boxes_min_max <- transform_box_to_min_max(true_boxes[[1]])
  pred_boxes_min_max <- transform_box_to_min_max(pred_boxes[[1]])

  bbox_scale <- 2 - true_boxes[[1]][ , , , , 3] * true_boxes[[1]][ , , , , 4]
  obj_mask <- tf$squeeze(true_boxes[[2]], axis = as.integer(-1))
  bbox_loss <- bbox_scale * obj_mask *
    tf$reduce_sum(tf$square(true_boxes[[1]] - pred_boxes[[1]]), axis = as.integer(-1))

  max_iou <- tf$map_fn(function(x) tf$reduce_max(
    get_max_boxes_iou(x[[1]],
                      tf$boolean_mask(x[[2]], tf$cast(x[[3]], tf$bool))), axis = as.integer(-1)),
    list(pred_boxes_min_max, true_boxes_min_max, obj_mask), tf$float32)
  ignore_mask <- tf$cast(max_iou < nonobj_threshold, tf$float32)
  obj_loss_bc <- tf$keras$losses$binary_crossentropy(true_boxes[[2]], pred_boxes[[2]])
  obj_loss <- obj_mask * obj_loss_bc
  noobj_loss <- (1 - obj_mask) * obj_loss_bc * ignore_mask

  class_loss <- 0
  for (cls in 1:n_class) {
    current_class_true <- tf$expand_dims(true_boxes[[3]][ , , , , cls], axis = as.integer(-1))
    current_class_false <- 1 - current_class_true
    current_class <- k_concatenate(list(current_class_true, current_class_false), axis = as.integer(-1))
    current_class_pred_true <- tf$expand_dims(pred_boxes[[3]][ , , , , cls], axis = as.integer(-1))
    current_class_pred_false <- 1 - current_class_pred_true
    current_class_pred <- k_concatenate(list(current_class_pred_true, current_class_pred_false), axis = as.integer(-1))
    current_class_bc <- tf$keras$losses$binary_crossentropy(current_class, current_class_pred)
    class_loss <- class_loss + class_weights[cls] * current_class_bc
  }
  class_loss <- obj_mask * class_loss

  bbox_loss <- bbox_lambda * tf$reduce_sum(bbox_loss, axis = as.integer(1:3))
  obj_loss <- obj_lambda * tf$reduce_sum(obj_loss, axis = as.integer(1:3))
  noobj_loss <- noobj_lambda * tf$reduce_sum(noobj_loss, axis = as.integer(1:3))
  class_loss <- class_lambda * tf$reduce_sum(class_loss, axis = as.integer(1:3))
  total_loss <- bbox_loss + obj_loss + noobj_loss + class_loss
  total_loss
}

#' Generates `Yolo3` loss function.
#' @description Generates `Yolo3` loss function.
#' @importFrom purrr imap
#' @param anchors Prediction anchors. For exact format check \code{\link[platypus]{coco_anchors}}.
#' @param n_class Number of prediction classes.
#' @param nonobj_threshold Non-object ignore threshold.
#' @param bbox_lambda Bounding box loss lambda.
#' @param obj_lambda Object loss lambda.
#' @param noobj_lambda Nonobject loss lambda.
#' @param class_lambda Class loss lambda.
#' @param class_weights Vector of length `n_class` with class weights.
#' @return `Yolo3` loss function.
#' @export
yolo3_loss <- function(anchors, n_class, nonobj_threshold = 0.5,
                       bbox_lambda = 1, obj_lambda = 1, noobj_lambda = 1,
                       class_lambda = 1, class_weights = rep(1, n_class)) {
  anchors %>% imap(~ {
    grid_id <- .y
    current_anchors <- .x
    custom_metric("yolo3_loss", function(y_true, y_pred) {
      yolo3_grid_loss(y_true, y_pred, current_anchors, n_class, nonobj_threshold,
                      bbox_lambda, obj_lambda, noobj_lambda, class_lambda,
                      class_weights)
    })
  }) %>% set_names(paste0("grid", 1:3))
}

#' Calculates IoU metric for one `Yolo3` grid.
#' @description Calculates IoU metric for one `Yolo3` grid.
#' @import tensorflow
#' @import keras
#' @param y_true Tensor of true coordinates/scores.
#' @param y_pred Tensor of predicted coordinates/scores.
#' @param anchors Prediction anchors (for one grid). For exact format check \code{\link[platypus]{coco_anchors}}.
#' @param n_class Number of prediction classes.
#' @return IoU metric for one `Yolo3` grid.
#' @export
yolo3_grid_iou <- function(y_true, y_pred, anchors, n_class) {
  true_boxes <- transform_boxes_tf(y_true, anchors, n_class, transform_proba = FALSE)
  pred_boxes <- transform_boxes_tf(y_pred, anchors, n_class, transform_proba = TRUE)
  true_boxes_min_max <- transform_box_to_min_max(true_boxes[[1]])
  pred_boxes_min_max <- transform_box_to_min_max(pred_boxes[[1]])

  obj_mask <- tf$squeeze(true_boxes[[2]], axis = as.integer(-1))
  iou <- calculate_iou(pred_boxes_min_max, true_boxes_min_max) * obj_mask
  mean_iou <- tf$reduce_sum(iou, axis = as.integer(1:3)) / tf$reduce_sum(obj_mask, axis = as.integer(1:3))
  tf$where(tf$math$is_nan(mean_iou), tf$ones_like(mean_iou), mean_iou)
}

#' Generates `Yolo3` IoU metric function.
#' @description Generates `Yolo3` IoU metric function.
#' @importFrom purrr map set_names
#' @param anchors Prediction anchors. For exact format check \code{\link[platypus]{coco_anchors}}.
#' @param n_class Number of prediction classes.
#' @return `Yolo3` IoU metric function.
#' @export
yolo3_metrics <- function(anchors, n_class) {
  anchors %>% map(~ {
    current_anchors <- .x
    custom_metric("avg_IoU", function(y_true, y_pred) {
      yolo3_grid_iou(y_true, y_pred, current_anchors, n_class)
    })
  }) %>% set_names(paste0("grid", 1:3))
}
